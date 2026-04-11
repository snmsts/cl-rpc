(in-package #:cl-rpc/handlers)

;;; -----------------------------------------------------------------------
;;; Connection State Management
;;; -----------------------------------------------------------------------

(defstruct connection-state
  "State corresponding to a single connection"
  backend
  ws-stream
  ;; Debugger-waiting flag: t while the eval thread is blocked in receive-if
  (in-debugger nil)
  ;; Write lock (prevents multiple notifications from being sent simultaneously)
  (write-lock (micros/backend:make-lock :name "ws-write-lock"))
  ;; Currently running eval thread (used for interrupt / debugger reply)
  (eval-thread nil))

;;; -----------------------------------------------------------------------
;;; Thread-safe WebSocket Sending
;;; -----------------------------------------------------------------------

(defmacro with-write-lock ((state) &body body)
  #+sbcl
  `(sb-sys:without-interrupts
     (micros/backend:call-with-lock-held
      (connection-state-write-lock ,state)
      (lambda () ,@body)))
  #-sbcl
  `(micros/backend:call-with-lock-held
    (connection-state-write-lock ,state)
    (lambda () ,@body)))

(defun safe-send-response (state id result)
  (with-write-lock (state)
    (send-response (connection-state-ws-stream state) id result)))

(defun safe-send-error (state id code message)
  (with-write-lock (state)
    (send-error (connection-state-ws-stream state) id code message)))

(defun safe-send-notification (state method params)
  (with-write-lock (state)
    (send-notification (connection-state-ws-stream state) method params)))

;;; -----------------------------------------------------------------------
;;; Gray Stream for Output Capturing
;;; -----------------------------------------------------------------------

(defclass output-capturing-stream (fundamental-character-output-stream)
  ((state  :initarg :state  :reader stream-state)
   (target :initarg :target :reader stream-target
           :documentation "\"stdout\" or \"stderr\"")
   (buffer :initform (make-array 256
                                 :element-type 'character
                                 :adjustable t
                                 :fill-pointer 0)
           :accessor stream-buffer)))

(defmethod stream-write-char ((s output-capturing-stream) char)
  (vector-push-extend char (stream-buffer s))
  (when (char= char #\newline)
    (flush-output-stream s))
  char)

(defmethod stream-write-string ((s output-capturing-stream) string
                                &optional (start 0) (end nil))
  (let ((end (or end (length string))))
    (loop for i from start below end
          do (vector-push-extend (char string i) (stream-buffer s)))
    (when (find #\newline string :start start :end end)
      (flush-output-stream s)))
  string)

(defmethod stream-finish-output ((s output-capturing-stream))
  (flush-output-stream s))

(defmethod stream-force-output ((s output-capturing-stream))
  (flush-output-stream s))

(defun flush-output-stream (s)
  "Send buffered characters as an output notification."
  (let ((buf (stream-buffer s)))
    (when (> (fill-pointer buf) 0)
      (let ((text (copy-seq buf))
            (params (make-hash-table :test #'equal)))
        (setf (fill-pointer buf) 0)
        (setf (gethash "text"   params) (coerce text 'string)
              (gethash "target" params) (stream-target s))
        (safe-send-notification (stream-state s) "output" params)))))

(defun make-output-capturing-stream (state target)
  "Create a Gray stream that forwards output as WebSocket notifications."
  (make-instance 'output-capturing-stream
                 :state state
                 :target target))

;;; -----------------------------------------------------------------------
;;; eval Handler
;;; -----------------------------------------------------------------------

(defun handle-eval (state id params)
  (let* ((backend      (connection-state-backend state))
         (code         (gethash "code" params))
         (package-name (or (gethash "package" params) "CL-USER"))
         (pkg          (find-package (string-upcase package-name)))
         (out-stream   (make-output-capturing-stream state "stdout"))
         (err-stream   (make-output-capturing-stream state "stderr"))
         (trace-stream (make-output-capturing-stream state "trace")))
    (unless pkg
      (safe-send-error state id -32001
                       (format nil "Package not found: ~A" package-name))
      (return-from handle-eval))
    (setf (connection-state-in-debugger state) nil)
    ;; pending-response holds a thunk that sends the eval response.
    ;; It is set before the eval block exits so that the unwind-protect cleanup
    ;; can send debug-return first and the response second (matching the spec).
    (let ((pending-response nil))
      (handler-bind
          ((serious-condition
             (lambda (c)
               (let ((info (backend-debugger-info backend c)))
                 (setf (connection-state-in-debugger state) t)
                 (safe-send-notification state "debug" info))
               (let ((choice (micros/backend:receive-if (constantly t))))
                 (destructuring-bind (action . args) choice
                   (ecase action
                     (:invoke-restart
                      (let* ((index (car args))
                             (value-str (cadr args))
                             (restarts (compute-restarts c)))
                        (when (< index (length restarts))
                          (if value-str
                              (invoke-restart (nth index restarts)
                                              (read-from-string value-str))
                              (invoke-restart (nth index restarts))))))
                     (:abort (abort c))))))))
        (let* ((*standard-output* out-stream)
               (*error-output*    err-stream)
               (*trace-output*    trace-stream)
               (*package*         pkg))
          (unwind-protect
               (block eval-block
                 (let* ((form (handler-case (read-from-string code)
                                (error (c)
                                  (setf (connection-state-in-debugger state) nil)
                                  (let ((msg (format nil "Read error: ~A" c)))
                                    (setf pending-response
                                          (lambda ()
                                            (safe-send-error state id -32000 msg))))
                                  (return-from eval-block))))
                        (results (restart-case
                                     (multiple-value-list (eval form))
                                   (abort ()
                                     :report "Abort evaluation"
                                     (setf pending-response
                                           (lambda ()
                                             (safe-send-error state id -32000
                                                              "Evaluation aborted")))
                                     (return-from eval-block))))
                        (value-strings (mapcar #'prin1-to-string results))
                        (result-params (make-hash-table :test #'equal)))
                   (flush-output-stream out-stream)
                   (flush-output-stream err-stream)
                   (setf (gethash "values"  result-params) (coerce value-strings 'vector)
                         (gethash "package" result-params)
                         (cl-rpc/backend:shortest-package-name *package*))
                   (let ((p result-params))
                     (setf pending-response
                           (lambda () (safe-send-response state id p))))))
            ;; Cleanup: per spec, debug-return is sent before the eval response.
            (when (connection-state-in-debugger state)
              (ignore-errors
                (let ((ret-params (make-hash-table :test #'equal)))
                  (setf (gethash "level" ret-params) 1)
                  (safe-send-notification state "debug-return" ret-params))))
            ;; Send the eval response (success, abort error, or read error).
            (when pending-response
              (ignore-errors (funcall pending-response)))
            (ignore-errors (flush-output-stream out-stream))
            (ignore-errors (flush-output-stream err-stream))
            (ignore-errors (flush-output-stream trace-stream))
            (setf (connection-state-in-debugger state) nil)
            (setf (connection-state-eval-thread state) nil)))))))

;;; -----------------------------------------------------------------------
;;; completions Handler
;;; -----------------------------------------------------------------------

(defun handle-completions (state id params)
  (let* ((backend      (connection-state-backend state))
         (prefix       (or (gethash "prefix" params) ""))
         (package-name (or (gethash "package" params) "CL-USER"))
         (internal     (gethash "internal" params))
         (limit        (gethash "limit" params))
         (candidates   (backend-completions backend prefix package-name internal limit))
         (items        (mapcar (lambda (c)
                                 (let ((h (make-hash-table :test #'equal)))
                                   (setf (gethash "label" h) (car c)
                                         (gethash "kind"  h) (cadr c))
                                   h))
                               candidates))
         (result       (make-hash-table :test #'equal)))
    (setf (gethash "candidates" result) (coerce items 'vector))
    (safe-send-response state id result)))

;;; -----------------------------------------------------------------------
;;; set-package Handler
;;; -----------------------------------------------------------------------

(defun handle-set-package (state id params)
  (let ((backend (connection-state-backend state))
        (name    (gethash "name" params)))
    (handler-case
        (let* ((new-pkg (backend-set-package backend name))
               (result  (make-hash-table :test #'equal)))
          (setf (gethash "package" result) new-pkg)
          (safe-send-response state id result))
      (error (c)
        (safe-send-error state id -32001 (princ-to-string c))))))

;;; -----------------------------------------------------------------------
;;; invoke-restart / abort Handler
;;; -----------------------------------------------------------------------

(defun handle-invoke-restart (state id params)
  "Select a restart in the debugger. If a value is provided, pass it to the restart."
  (let ((index       (gethash "index" params))
        (value-str   (gethash "value" params))
        (eval-thread (connection-state-eval-thread state)))
    (if (and eval-thread (connection-state-in-debugger state))
        (progn
          (micros/backend:send eval-thread
                               (cons :invoke-restart (list index value-str)))
          (safe-send-response state id (make-hash-table :test #'equal)))
        (safe-send-error state id -32000 "No active debugger session"))))

(defun handle-abort (state id params)
  "Abort from the debugger."
  (declare (ignore params))
  (let ((eval-thread (connection-state-eval-thread state)))
    (if (and eval-thread (connection-state-in-debugger state))
        (progn
          (micros/backend:send eval-thread (cons :abort nil))
          (safe-send-response state id (make-hash-table :test #'equal)))
        (safe-send-error state id -32000 "No active debugger session"))))

;;; -----------------------------------------------------------------------
;;; interrupt Handler
;;; -----------------------------------------------------------------------

(defun handle-interrupt (state id params)
  "Interrupt the currently running eval thread by injecting an abort."
  (declare (ignore params))
  (let ((thread (connection-state-eval-thread state)))
    (if thread
        (progn
          (micros/backend:interrupt-thread
           thread
           (lambda ()
             #+sbcl (signal 'sb-sys:interactive-interrupt)
             #-sbcl (error "Interrupted")))
          (safe-send-response state id (make-hash-table :test #'equal)))
        (safe-send-error state id -32000 "No active eval"))))

;;; -----------------------------------------------------------------------
;;; macroexpand Handler
;;; -----------------------------------------------------------------------

(defun handle-macroexpand (state id params)
  (let ((backend (connection-state-backend state))
        (code    (gethash "code" params))
        (package (or (gethash "package" params) "CL-USER"))
        (all     (gethash "all" params)))
    (handler-case
        (safe-send-response state id
                            (backend-macroexpand backend code package all))
      (error (c)
        (safe-send-error state id -32000 (princ-to-string c))))))

;;; -----------------------------------------------------------------------
;;; describe Handler
;;; -----------------------------------------------------------------------

(defun handle-describe (state id params)
  (let ((backend (connection-state-backend state))
        (symbol  (gethash "symbol" params))
        (package (or (gethash "package" params) "CL-USER")))
    (handler-case
        (safe-send-response state id
                            (backend-describe backend symbol package))
      (error (c)
        (safe-send-error state id -32000 (princ-to-string c))))))

;;; -----------------------------------------------------------------------
;;; find-definitions Handler
;;; -----------------------------------------------------------------------

(defun handle-find-definitions (state id params)
  (let ((backend (connection-state-backend state))
        (symbol  (gethash "symbol" params))
        (package (or (gethash "package" params) "CL-USER")))
    (handler-case
        (let* ((defs (backend-find-definitions backend symbol package))
               (items (mapcar (lambda (d)
                                (let ((h (make-hash-table :test #'equal)))
                                  (setf (gethash "name"     h) (first d)
                                        (gethash "type"     h) (second d)
                                        (gethash "file"     h) (third d)
                                        (gethash "position" h) (fourth d))
                                  h))
                              defs))
               (result (make-hash-table :test #'equal)))
          (setf (gethash "definitions" result) (coerce items 'vector))
          (safe-send-response state id result))
      (error (c)
        (safe-send-error state id -32000 (princ-to-string c))))))

;;; -----------------------------------------------------------------------
;;; apropos Handler
;;; -----------------------------------------------------------------------

(defun handle-apropos (state id params)
  (let ((pattern  (gethash "pattern" params))
        (package  (gethash "package" params)))
    (handler-case
        (let* ((syms (if package
                         (apropos-list pattern (find-package (string-upcase package)))
                         (apropos-list pattern)))
                (items (mapcar (lambda (s)
                                 (let ((h (make-hash-table :test #'equal)))
                                   (setf (gethash "name"    h) (symbol-name s)
                                         (gethash "package" h) (if (symbol-package s)
                                                                    (cl-rpc/backend:shortest-package-name
                                                                     (symbol-package s))
                                                                    nil)
                                         (gethash "kind"    h) (cl-rpc/backend:symbol-kind s))
                                   h))
                               syms))
               (result (make-hash-table :test #'equal)))
          (setf (gethash "symbols" result) (coerce items 'vector))
          (safe-send-response state id result))
      (error (c)
        (safe-send-error state id -32000 (princ-to-string c))))))

;;; -----------------------------------------------------------------------
;;; xref Handler
;;; -----------------------------------------------------------------------

(defun %xref-results-to-vector (results)
  "Convert micros xref results of the form ((name . location) ...) to a vector suitable for JSON."
  (coerce
   (mapcar (lambda (entry)
             (let ((h    (make-hash-table :test #'equal))
                   (name (car entry))
                   (loc  (cdr entry)))
               (setf (gethash "name" h) (princ-to-string name))
               (when (and (consp loc) (eq (car loc) :location))
                 (dolist (part (cdr loc))
                   (when (consp part)
                     (case (car part)
                       (:file     (setf (gethash "file"     h) (cadr part)))
                       (:position (setf (gethash "position" h) (cadr part)))))))
               h))
           results)
   'vector))

(defun %handle-xref (state id params micros-fn)
  (let* ((symbol-name  (gethash "symbol" params))
         (package-name (or (gethash "package" params) "CL-USER")))
    (handler-case
        (let* ((pkg (or (find-package (string-upcase package-name))
                        (error "Package not found: ~A" package-name)))
               (sym (or (find-symbol (string-upcase symbol-name) pkg)
                        (error "Symbol not found: ~A in ~A" symbol-name package-name)))
               (xrefs  (funcall micros-fn sym))
               (result (make-hash-table :test #'equal)))
          (setf (gethash "xrefs" result) (%xref-results-to-vector xrefs))
          (safe-send-response state id result))
      (error (c)
        (safe-send-error state id -32000 (princ-to-string c))))))

(defun handle-xref-callers (state id params)
  (%handle-xref state id params #'micros/backend:list-callers))

(defun handle-xref-callees (state id params)
  (%handle-xref state id params #'micros/backend:list-callees))

(defun handle-xref-references (state id params)
  (%handle-xref state id params #'micros/backend:who-references))

;;; -----------------------------------------------------------------------
;;; trace / untrace Handler
;;; -----------------------------------------------------------------------

(defun handle-trace (state id params)
  (let ((symbol-name (gethash "symbol" params)))
    (handler-case
        (let* ((spec   (read-from-string (string-upcase symbol-name)))
               (result (make-hash-table :test #'equal)))
          (eval `(cl:trace ,spec))
          (setf (gethash "message" result)
                (format nil "~A is now traced." spec))
          (safe-send-response state id result))
      (error (c)
        (safe-send-error state id -32000 (princ-to-string c))))))

(defun handle-untrace (state id params)
  (let ((symbol-name (gethash "symbol" params)))
    (handler-case
        (let* ((result (make-hash-table :test #'equal))
               (msg    (if symbol-name
                           (progn
                             (eval `(untrace ,(read-from-string (string-upcase symbol-name))))
                             (format nil "~A is now untraced." symbol-name))
                           (progn
                             (untrace)
                             "All functions untraced."))))
          (setf (gethash "message" result) msg)
          (safe-send-response state id result))
      (error (c)
        (safe-send-error state id -32000 (princ-to-string c))))))

;;; -----------------------------------------------------------------------
;;; threads Handler
;;; -----------------------------------------------------------------------

(defun handle-threads (state id params)
  (declare (ignore params))
  (handler-case
      (let* ((data   (micros:list-threads))
             ;; data = (labels row1 row2 ...) where labels = (:id :name :status ...)
             (labels (first data))
             (rows   (rest data))
             (id-idx     (position :id     labels))
             (name-idx   (position :name   labels))
             (status-idx (position :status labels))
             (items  (mapcar (lambda (row)
                               (let ((h (make-hash-table :test #'equal)))
                                 (when id-idx
                                   (setf (gethash "id" h) (nth id-idx row)))
                                 (when name-idx
                                   (setf (gethash "name" h) (nth name-idx row)))
                                 (when status-idx
                                   (setf (gethash "status" h) (nth status-idx row)))
                                 h))
                             rows))
             (result (make-hash-table :test #'equal)))
        (setf (gethash "threads" result) (coerce items 'vector))
        (safe-send-response state id result))
    (error (c)
      (safe-send-error state id -32000 (princ-to-string c)))))

;;; -----------------------------------------------------------------------
;;; capabilities Handler
;;; -----------------------------------------------------------------------

(defparameter *protocol-version* "1.0")

;;; NOTE: When adding a method, update this list together with dispatch-request
(defparameter *supported-methods*
  '("eval" "completions" "set-package"
    "macroexpand" "describe" "find-definitions"
    "apropos"
    "xref-callers" "xref-callees" "xref-references"
    "trace" "untrace" "threads"
    "invoke-restart" "abort" "interrupt"
    "capabilities"))

(defparameter *supported-notifications*
  '("welcome" "output" "debug" "debug-return"))

(defun handle-capabilities (state id params)
  (declare (ignore params))
  (let ((result (make-hash-table :test #'equal)))
    (setf (gethash "methods"       result) (coerce *supported-methods*       'vector)
          (gethash "notifications" result) (coerce *supported-notifications* 'vector))
    (safe-send-response state id result)))

(defun send-welcome (state)
  "Send a welcome notification immediately after a connection is established."
  (let ((params (make-hash-table :test #'equal)))
    (setf (gethash "protocol-version"      params) *protocol-version*
          (gethash "implementation"        params) (lisp-implementation-type)
          (gethash "implementation-version" params) (lisp-implementation-version))
    (safe-send-notification state "welcome" params)))

;;; -----------------------------------------------------------------------
;;; Dispatch
;;; -----------------------------------------------------------------------

(defun dispatch-request (state json-string)
  "Parse a JSON-RPC request and dispatch it to the appropriate handler."
  (handler-case
      (let ((req (parse-request json-string)))
        (let ((method  (request-method req))
              (id      (request-id     req))
              (params  (or (request-params req)
                           (make-hash-table :test #'equal))))
          (cond
            ((string= method "eval")
             (if (connection-state-in-debugger state)
                 (when id
                   (safe-send-error state id -32000
                                    "Cannot evaluate while the debugger is active"))
                 (let ((thread (micros/backend:spawn
                                (lambda ()
                                  (handle-eval state id params))
                                :name (format nil "cl-rpc-eval-~A" id))))
                   (setf (connection-state-eval-thread state) thread))))
            ((string= method "completions")
             (handle-completions state id params))
            ((string= method "set-package")
             (handle-set-package state id params))
            ((string= method "invoke-restart")
             (handle-invoke-restart state id params))
            ((string= method "abort")
             (handle-abort state id params))
            ((string= method "interrupt")
             (handle-interrupt state id params))
            ((string= method "macroexpand")
             (handle-macroexpand state id params))
            ((string= method "describe")
             (handle-describe state id params))
            ((string= method "find-definitions")
             (handle-find-definitions state id params))
            ((string= method "apropos")
             (handle-apropos state id params))
            ((string= method "xref-callers")
             (handle-xref-callers state id params))
            ((string= method "xref-callees")
             (handle-xref-callees state id params))
            ((string= method "xref-references")
             (handle-xref-references state id params))
            ((string= method "trace")
             (handle-trace state id params))
            ((string= method "untrace")
             (handle-untrace state id params))
            ((string= method "threads")
             (handle-threads state id params))
            ((string= method "capabilities")
             (handle-capabilities state id params))
            (t
             (when id
               (safe-send-error state id -32601
                                (format nil "Method not found: ~A" method)))))))
    (error (c)
      (safe-send-error state nil -32700
                       (format nil "Parse error: ~A" c)))))
