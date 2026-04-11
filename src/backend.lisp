(in-package #:cl-rpc/backend)

;;; -----------------------------------------------------------------------
;;; Backend generic function interface
;;; -----------------------------------------------------------------------

(defgeneric backend-eval (backend code package-name)
  (:documentation
   "Evaluate code in the package named package-name.
   Returns (values result-strings new-package-name).
   result-strings: a list of strings, each produced by prin1-to-string on each result value."))

(defgeneric backend-completions (backend prefix package-name &optional internal limit)
  (:documentation
   "Return a list of completion candidates. Each element is a list of (label kind).
   If internal is true, use do-symbols (all accessible symbols including inherited ones);
   otherwise use do-external-symbols.
   If limit is non-nil, restrict the number of candidates to that value.
   kind: \"function\" | \"macro\" | \"variable\" | \"class\" | \"keyword\" | \"unknown\""))

(defgeneric backend-set-package (backend name)
  (:documentation
   "Change the current package to the one named name. Returns the new package name as a string.
   Signals an error if the package does not exist."))

(defgeneric backend-macroexpand (backend code package-name &optional all)
  (:documentation
   "Macroexpand code and return the result as a pretty-printed string.
   If all is true, use macroexpand-all; otherwise use macroexpand-1."))

(defgeneric backend-describe (backend symbol-name package-name)
  (:documentation
   "Return information about a symbol as a hash-table (name, type, args, docstring, package)."))

(defgeneric backend-find-definitions (backend symbol-name package-name)
  (:documentation
   "Return a list of definition locations for a symbol. Each element is (name type file position)."))

(defgeneric backend-debugger-info (backend condition)
  (:documentation
   "Build and return a params hash-table for a debugger notification from condition."))

(defgeneric backend-invoke-restart (backend level index)
  (:documentation
   "Select the restart at the given level and index in the debugger."))

(defgeneric backend-abort (backend level)
  (:documentation
   "Abort from the debugger and return to the specified level."))

;;; -----------------------------------------------------------------------
;;; SBCL backend
;;; -----------------------------------------------------------------------

(defclass backend ()
  ()
  (:documentation "SBCL-specific backend implementation."))

(defun shortest-package-name (pkg)
  "Return the shortest name for a package (the shortest among its nicknames, if any)."
  (let ((name (package-name pkg))
        (nicknames (package-nicknames pkg)))
    (if nicknames
        (reduce (lambda (a b) (if (<= (length a) (length b)) a b))
                nicknames :initial-value name)
      name)))

(defun symbol-kind (sym)
  "Return the kind of a symbol as a string."
  (cond
    ((special-operator-p sym) "special-form")
    ((macro-function sym)     "macro")
    ((fboundp sym)            "function")
    ((boundp sym)             "variable")
    ((find-class sym nil)     "class")
    ((keywordp sym)           "keyword")
    (t                        "unknown")))

(defmethod backend-completions ((b backend) prefix package-name &optional internal limit)
  "Return completion candidates whose names start with prefix.
   If internal is true, use do-symbols (all accessible symbols including inherited ones);
   otherwise use do-external-symbols.
   If limit is non-nil, restrict the number of candidates to that value."
  (let ((pkg (find-package (string-upcase package-name))))
    (unless pkg
      (return-from backend-completions nil))
    (let ((candidates '())
          (prefix-len (length prefix)))
      (flet ((check (sym)
               (let ((name (string-downcase (symbol-name sym))))
                 (when (and (>= (length name) prefix-len)
                            (string= prefix name :end2 prefix-len))
                   (pushnew (list name (symbol-kind sym)) candidates :test #'equal)))))
        (if internal
            (do-symbols (sym pkg) (check sym))
            (do-external-symbols (sym pkg) (check sym))))
      (let ((sorted (sort candidates #'string< :key #'car)))
        (if limit
            (subseq sorted 0 (min limit (length sorted)))
            sorted)))))

(defmethod backend-set-package ((b backend) name)
  "Change the current package."
  (let ((pkg (find-package (string-upcase name))))
    (if pkg
        (progn
          (setf *package* pkg)
          (shortest-package-name pkg))
        (error "Package ~A not found" name))))

(defmethod backend-debugger-info ((b backend) condition)
  "Build the params hash-table for a debugger notification from condition."
  (let ((restarts (compute-restarts condition))
        (params (make-hash-table :test #'equal)))
    ;; restarts list
    (let ((restart-list
            (loop for r in restarts
                  for i from 0
                  collect (let ((h (make-hash-table :test #'equal)))
                            (setf (gethash "index"       h) i
                                  (gethash "name"        h) (string (restart-name r))
                                  (gethash "description" h) (princ-to-string r))
                            h))))
      ;; frames (SBCL backtrace)
      (let ((frames
              #+sbcl
              (handler-case
                  (let ((result '())
                        (index 0))
                    (sb-debug:map-backtrace
                     (lambda (frame)
                       (let ((h (make-hash-table :test #'equal)))
                         (setf (gethash "index"       h) index
                               (gethash "description" h)
                               (with-output-to-string (s)
                                 (print-object frame s)))
                         (push h result)
                         (incf index)))
                     :count 20)
                    (nreverse result))
                (error () nil))
              #-sbcl nil))
        (setf (gethash "level"     params) 1
              (gethash "condition" params) (princ-to-string condition)
              (gethash "restarts"  params) (coerce restart-list 'vector)
              (gethash "frames"    params) (coerce (or frames '()) 'vector))
        params))))

;;; invoke-restart and abort are executed by the handler side in debugger integration,
;;; so only stubs are defined here.
(defmethod backend-invoke-restart ((b backend) level index)
  (declare (ignore b level index))
  ;; The actual restart invocation is performed via the mailbox in handler.lisp.
  nil)

(defmethod backend-abort ((b backend) level)
  (declare (ignore b level))
  nil)

(defmethod backend-macroexpand ((b backend) code package-name &optional all)
  (let* ((pkg (or (find-package (string-upcase package-name))
                  (error "Package not found: ~A" package-name)))
         (*package* pkg)
         (form (read-from-string code))
         (expanded (if all (macroexpand form) (macroexpand-1 form)))
         (result (make-hash-table :test #'equal)))
    (setf (gethash "expansion" result)
          (with-output-to-string (s)
            (let ((*package* pkg))
              (pprint expanded s))))
    result))

(defun %symbol-type (sym)
  "Return the type of a symbol as a string (for describe; more detailed than symbol-kind)."
  (cond
    ((special-operator-p sym) "special-form")
    ((macro-function sym)     "macro")
    #+sbcl
    ((and (fboundp sym)
          (typep (fdefinition sym) 'generic-function))
     "generic-function")
    ((fboundp sym)            "function")
    ((boundp sym)             "variable")
    ((find-class sym nil)     "class")
    (t                        "unknown")))

(defmethod backend-describe ((b backend) symbol-name package-name)
  (let* ((pkg (or (find-package (string-upcase package-name))
                  (error "Package not found: ~A" package-name)))
         (sym (find-symbol (string-upcase symbol-name) pkg)))
    (unless sym
      (error "Symbol not found: ~A in ~A" symbol-name package-name))
    (let ((result (make-hash-table :test #'equal))
          (sym-type (%symbol-type sym)))
      (setf (gethash "name" result) (symbol-name sym)
            (gethash "type" result) sym-type
            (gethash "package" result) (shortest-package-name (symbol-package sym)))
      ;; arglist: always present in result; null for non-functions/macros
      #+sbcl
      (when (member sym-type '("function" "macro" "generic-function") :test #'string=)
        (setf (gethash "args" result)
              (princ-to-string (sb-introspect:function-lambda-list sym))))
      (multiple-value-bind (v present) (gethash "args" result)
        (declare (ignore v))
        (unless present
          (setf (gethash "args" result) nil)))
      ;; docstring: always present in result; null if no documentation found
      (setf (gethash "docstring" result)
            (or (documentation sym 'function)
                (documentation sym 'variable)
                (documentation sym 'type)))
      result)))

(defun %parse-micros-location (loc)
  "Parse a micros (:location (:file ...) (:position N) ...) form and return (file . position).
   Returns nil if no file entry is found."
  (when (and (consp loc) (eq (car loc) :location))
    (let ((file nil) (pos 0))
      (dolist (entry (cdr loc))
        (when (consp entry)
          (case (car entry)
            (:file     (setf file (cadr entry)))
            (:position (setf pos  (cadr entry))))))
      (when file (cons file pos)))))

(defmethod backend-find-definitions ((b backend) symbol-name package-name)
  "Retrieve the definition locations of a symbol using micros/backend:find-definitions."
  (let* ((pkg (or (find-package (string-upcase package-name))
                  (error "Package not found: ~A" package-name)))
         (sym (find-symbol (string-upcase symbol-name) pkg)))
    (unless sym
      (error "Symbol not found: ~A in ~A" symbol-name package-name))
    (let ((defs '()))
      (dolist (entry (micros/backend::find-definitions sym))
        (let* ((dspec (first entry))
               (loc   (second entry))
               (parsed (%parse-micros-location loc)))
          (when parsed
            (push (list (format nil "~A:~A"
                                (if (symbol-package sym)
                                    (shortest-package-name (symbol-package sym))
                                    "#")
                                (symbol-name sym))
                        (format nil "~A" dspec)
                        (if (pathnamep (car parsed))
                            (namestring (car parsed))
                            (car parsed))
                        (cdr parsed))
                  defs))))
      (nreverse defs))))
