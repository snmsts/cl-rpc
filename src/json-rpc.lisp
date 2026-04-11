(in-package #:cl-rpc/json-rpc)

;;; -----------------------------------------------------------------------
;;; JSON parser (minimal inline implementation)
;;; -----------------------------------------------------------------------

(defun %json-skip-ws (str pos)
  (loop while (and (< pos (length str))
                   (member (char str pos) '(#\space #\tab #\newline #\return)))
        do (incf pos))
  pos)

(defun %json-parse-string (str pos)
  "pos is the position immediately after the opening \". Returns (values string new-pos)."
  (let ((buf (make-array 64 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop
      (when (>= pos (length str))
        (error "Unterminated JSON string"))
      (let ((ch (char str pos)))
        (incf pos)
        (cond
          ((char= ch #\")
           (return (values (coerce buf 'string) pos)))
          ((char= ch #\\)
           (when (>= pos (length str)) (error "Unterminated escape"))
           (let ((esc (char str pos)))
             (incf pos)
             (vector-push-extend
              (case esc
                (#\" #\") (#\\ #\\) (#\/ #\/)
                (#\b #\backspace) (#\f #\page)
                (#\n #\newline) (#\r #\return) (#\t #\tab)
                (#\u
                 (let ((hex (subseq str pos (+ pos 4))))
                   (incf pos 4)
                   (code-char (parse-integer hex :radix 16))))
                (t (error "Unknown JSON escape \\~C" esc)))
              buf)))
          (t
           (vector-push-extend ch buf)))))))

(defun %json-parse-number (str pos)
  (let ((start pos))
    (when (char= (char str pos) #\-) (incf pos))
    (loop while (and (< pos (length str)) (digit-char-p (char str pos)))
          do (incf pos))
    (let ((floatp nil))
      (when (and (< pos (length str)) (char= (char str pos) #\.))
        (setf floatp t)
        (incf pos)
        (loop while (and (< pos (length str)) (digit-char-p (char str pos)))
              do (incf pos)))
      (when (and (< pos (length str)) (member (char str pos) '(#\e #\E)))
        (setf floatp t)
        (incf pos)
        (when (and (< pos (length str)) (member (char str pos) '(#\+ #\-)))
          (incf pos))
        (loop while (and (< pos (length str)) (digit-char-p (char str pos)))
              do (incf pos)))
      (let ((s (subseq str start pos)))
        (values (if floatp
                    (let ((*read-default-float-format* 'double-float))
                      (read-from-string s))
                    (parse-integer s))
                pos)))))

(defun %json-parse (str pos)
  "Parses a JSON value from str starting at pos. Returns (values value new-pos)."
  (setf pos (%json-skip-ws str pos))
  (when (>= pos (length str))
    (error "Unexpected end of JSON input"))
  (let ((ch (char str pos)))
    (cond
      ((char= ch #\{)
       (let ((obj (make-hash-table :test #'equal)))
         (setf pos (%json-skip-ws str (1+ pos)))
         (if (char= (char str pos) #\})
             (values obj (1+ pos))
             (loop
               (unless (char= (char str pos) #\")
                 (error "Expected string key in JSON object"))
               (multiple-value-bind (key kpos) (%json-parse-string str (1+ pos))
                 (setf pos (%json-skip-ws str kpos))
                 (unless (char= (char str pos) #\:)
                   (error "Expected : after JSON object key"))
                 (multiple-value-bind (val vpos) (%json-parse str (1+ pos))
                   (setf (gethash key obj) val)
                   (setf pos (%json-skip-ws str vpos))
                   (let ((sep (char str pos)))
                     (incf pos)
                     (cond
                       ((char= sep #\}) (return (values obj pos)))
                       ((char= sep #\,))
                       (t (error "Expected , or } in JSON object"))))))))))
      ((char= ch #\[)
       (let ((items '()))
         (setf pos (%json-skip-ws str (1+ pos)))
         (if (char= (char str pos) #\])
             (values (make-array 0) (1+ pos))
             (loop
               (multiple-value-bind (val vpos) (%json-parse str pos)
                 (push val items)
                 (setf pos (%json-skip-ws str vpos))
                 (let ((sep (char str pos)))
                   (incf pos)
                   (cond
                     ((char= sep #\]) (return (values (coerce (nreverse items) 'vector) pos)))
                     ((char= sep #\,))
                     (t (error "Expected , or ] in JSON array")))))))))
      ((char= ch #\")
       (%json-parse-string str (1+ pos)))
      ((or (char= ch #\-) (digit-char-p ch))
       (%json-parse-number str pos))
      ((and (<= (+ pos 4) (length str)) (string= str "true" :start1 pos :end1 (+ pos 4)))
       (values t (+ pos 4)))
      ((and (<= (+ pos 5) (length str)) (string= str "false" :start1 pos :end1 (+ pos 5)))
       (values nil (+ pos 5)))
      ((and (<= (+ pos 4) (length str)) (string= str "null" :start1 pos :end1 (+ pos 4)))
       (values nil (+ pos 4)))
      (t
       (error "Unexpected character ~S at position ~D in JSON" ch pos)))))

(defun json-parse (str)
  "Parses a JSON string and returns a Lisp object."
  (nth-value 0 (%json-parse str 0)))

;;; -----------------------------------------------------------------------
;;; JSON stringifier (minimal inline implementation)
;;; -----------------------------------------------------------------------

(defun %json-write-string (str out)
  (write-char #\" out)
  (loop for ch across str
        do (case ch
             (#\"        (write-string "\\\"" out))
             (#\\        (write-string "\\\\" out))
             (#\newline  (write-string "\\n" out))
             (#\return   (write-string "\\r" out))
             (#\tab      (write-string "\\t" out))
             (t
              (let ((code (char-code ch)))
                (if (< code 32)
                    (format out "\\u~4,'0X" code)
                    (write-char ch out))))))
  (write-char #\" out))

(defun %json-write (val out)
  (cond
    ((null val)
     (write-string "null" out))
    ((eq val t)
     (write-string "true" out))
    ((stringp val)
     (%json-write-string val out))
    ((integerp val)
     (format out "~D" val))
    ((numberp val)
     (format out "~S" (coerce val 'double-float)))
    ((hash-table-p val)
     (write-char #\{ out)
     (let ((first t))
       (maphash (lambda (k v)
                  (unless first (write-char #\, out))
                  (setf first nil)
                  (%json-write-string (if (stringp k) k (format nil "~A" k)) out)
                  (write-char #\: out)
                  (%json-write v out))
                val))
     (write-char #\} out))
    ((vectorp val)
     (write-char #\[ out)
     (loop for i below (length val)
           do (when (> i 0) (write-char #\, out))
              (%json-write (aref val i) out))
     (write-char #\] out))
    (t
     (error "Cannot JSON-stringify ~S" val))))

(defun json-stringify (val)
  "Serializes a Lisp object to a JSON string."
  (with-output-to-string (out)
    (%json-write val out)))

;;; -----------------------------------------------------------------------
;;; Request struct
;;; -----------------------------------------------------------------------

(defstruct (request (:constructor make-request (id method params)))
  id
  method
  params)

(defun parse-request (json-string)
  "Parses a JSON string and returns a request struct."
  (let ((obj (json-parse json-string)))
    (make-request
     (gethash "id" obj)
     (gethash "method" obj)
     (gethash "params" obj))))

;;; -----------------------------------------------------------------------
;;; Response / notification sending
;;; -----------------------------------------------------------------------

(defvar *debug-log* nil
  "When nil, logging is disabled. When t, output goes to *real-error-output*. When set to a stream, output goes to that stream.")

(defvar *real-error-output* *error-output*
  "Saves the value of *error-output* at startup (before it is replaced by a Gray stream).")

(defun %log (fmt &rest args)
  (when *debug-log*
    (let ((stream (if (streamp *debug-log*) *debug-log* *real-error-output*)))
      (apply #'format stream fmt args)
      (finish-output stream))))

(defun %send (ws-stream json)
  (%log "~&[send] ~A~%" json)
  (cl-rpc/websocket:write-text-frame ws-stream json))

(defun send-response (ws-stream id result)
  "Writes a JSON-RPC 2.0 response to a WebSocket stream."
  (let ((msg (make-hash-table :test #'equal)))
    (setf (gethash "jsonrpc" msg) "2.0"
          (gethash "id"      msg) id
          (gethash "result"  msg) result)
    (%send ws-stream (json-stringify msg))))

(defun send-error (ws-stream id code message)
  "Writes a JSON-RPC 2.0 error response to a WebSocket stream."
  (let ((err (make-hash-table :test #'equal))
        (msg (make-hash-table :test #'equal)))
    (setf (gethash "code"    err) code
          (gethash "message" err) message)
    (setf (gethash "jsonrpc" msg) "2.0"
          (gethash "id"      msg) id
          (gethash "error"   msg) err)
    (%send ws-stream (json-stringify msg))))

(defun send-notification (ws-stream method params)
  "Writes a JSON-RPC 2.0 notification (without id) to a WebSocket stream."
  (let ((msg (make-hash-table :test #'equal)))
    (setf (gethash "jsonrpc" msg) "2.0"
          (gethash "method"  msg) method
          (gethash "params"  msg) params)
    (%send ws-stream (json-stringify msg))))
