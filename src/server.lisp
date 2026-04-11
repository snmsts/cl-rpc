(in-package #:cl-rpc)

;;; -----------------------------------------------------------------------
;;; Static file serving
;;; -----------------------------------------------------------------------

(defvar *static-dir* nil
  "Directory from which static files are served. nil means no static serving.")

(defparameter *content-types*
  '(("html" . "text/html; charset=utf-8")
    ("js"   . "application/javascript; charset=utf-8")
    ("mjs"  . "application/javascript; charset=utf-8")
    ("css"  . "text/css; charset=utf-8")
    ("json" . "application/json; charset=utf-8")
    ("wasm" . "application/wasm")
    ("png"  . "image/png")
    ("jpg"  . "image/jpeg")
    ("svg"  . "image/svg+xml")
    ("ico"  . "image/x-icon"))
  "File extension to Content-Type mapping.")

(defun path-content-type (path)
  "Return the Content-Type string for the given pathname."
  (let* ((type (pathname-type path))
         (ext  (if type (string-downcase type) ""))
         (found (assoc ext *content-types* :test #'string=)))
    (if found (cdr found) "application/octet-stream")))

(defun safe-static-path (static-dir request-path)
  "Resolve request-path to a safe path under static-dir.
  Returns nil if a directory traversal attempt is detected."
  (let* ((stripped  (string-left-trim "/" request-path))
         (base      (uiop:ensure-directory-pathname static-dir))
         (candidate (uiop:merge-pathnames* stripped base))
         (base-str  (namestring base))
         (cand-str  (namestring candidate)))
    (when (and (>= (length cand-str) (length base-str))
               (string= base-str cand-str :end2 (length base-str)))
      candidate)))

(defun parse-request-line (line)
  "Parse \"GET /path HTTP/1.1\" into (values method path), or nil for all values on failure."
  (let* ((sp1 (position #\space line))
         (sp2 (when sp1 (position #\space line :start (1+ sp1)))))
    (when (and sp1 sp2)
      (values (subseq line 0 sp1)
              (subseq line (1+ sp1) sp2)))))

(defun string-to-ascii-octets (str)
  "Convert a string to a vector of ASCII octets."
  (map '(vector (unsigned-byte 8)) #'char-code str))

(defun read-file-to-octets (path)
  "Read a file and return its contents as an octet vector."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let* ((len (file-length in))
           (buf (make-array len :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))

(defun write-http-response (stream status-code status-text content-type body-octets)
  "Write an HTTP/1.1 response to a binary stream."
  (let ((crlf (coerce '(13 10) '(vector (unsigned-byte 8)))))
    (flet ((write-header-line (str)
             (write-sequence (string-to-ascii-octets str) stream)
             (write-sequence crlf stream)))
      (write-header-line (format nil "HTTP/1.1 ~D ~A" status-code status-text))
      (write-header-line (format nil "Content-Type: ~A" content-type))
      (write-header-line (format nil "Content-Length: ~D" (length body-octets)))
      (write-header-line "Connection: close")
      (write-sequence crlf stream)
      (write-sequence body-octets stream)
      (finish-output stream))))

(defun send-404 (stream)
  (write-http-response stream 404 "Not Found" "text/plain"
                       (micros/backend:string-to-utf8 "404 Not Found")))

(defun handle-http-get (stream request-path)
  "Serve a static file in response to a GET request."
  (unless *static-dir*
    (send-404 stream)
    (return-from handle-http-get))
  (let* ((path      (if (or (string= request-path "/") (string= request-path ""))
                        "/index.html"
                        request-path))
         (file-path (safe-static-path *static-dir* path)))
    (cond
      ((null file-path)
       (send-404 stream))
      ((probe-file file-path)
       (write-http-response stream 200 "OK"
                            (path-content-type file-path)
                            (read-file-to-octets file-path)))
      (t
       (send-404 stream)))))

;;; -----------------------------------------------------------------------
;;; Connection handlers
;;; -----------------------------------------------------------------------

(defun handle-websocket-connection (stream lines)
  "Perform the WebSocket handshake and run the frame receive loop."
  (cl-rpc/websocket:handshake stream :lines lines)
  (let ((state (cl-rpc/handlers:make-connection-state
                :backend   (make-instance 'cl-rpc/backend:backend)
                :ws-stream stream)))
    (cl-rpc/handlers:send-welcome state)
    (loop
      (multiple-value-bind (type payload)
          (cl-rpc/websocket:read-frame stream)
        (case type
          (:text
           (cl-rpc/json-rpc::%log "~&[recv] ~A~%" payload)
           (cl-rpc/handlers:dispatch-request state payload))
          (:ping
           (cl-rpc/websocket:write-pong-frame stream))
          (:close
           (cl-rpc/websocket:write-close-frame stream)
           (return))
          (t nil))))))

(defun handle-connection (stream)
  "Handle a single client connection."
  (handler-case
      (let* ((lines   (cl-rpc/websocket:read-http-request-lines stream))
             (upgrade (cl-rpc/websocket:extract-header lines "Upgrade")))
        (cond
          ((and upgrade (string-equal upgrade "websocket"))
           (handle-websocket-connection stream lines))
          (t
           (multiple-value-bind (method path)
               (parse-request-line (or (car lines) ""))
             (if (and method (string= method "GET"))
                 (handle-http-get stream path)
                 (send-404 stream))))))
    (end-of-file ()
      nil)
    (error (c)
      (format *error-output* "Connection error: ~A~%" c)))
  (handler-case
      (close stream)
    (error () nil)))

;;; -----------------------------------------------------------------------
;;; Server start / stop
;;; -----------------------------------------------------------------------

(defvar *server-socket* nil
  "The currently running server socket.")

(defvar *server-thread* nil
  "The server's main thread.")

(defun start-server (&key (port 7654) (host "127.0.0.1") debug static-dir)
  "Start the WebSocket + JSON-RPC server.
   port:       port to listen on (default 7654)
   host:       address to bind to (default \"127.0.0.1\")
   debug:      nil=disabled, t=log to *error-output*, stream=log to that stream
   static-dir: directory to serve static files from (nil disables static serving)"
  (setf cl-rpc/json-rpc:*debug-log* debug)
  (setf *static-dir* (when static-dir (uiop:ensure-directory-pathname static-dir)))
  (when *server-socket*
    (warn "Server is already running. Call stop-server first."))
  (let* ((micros::*communication-style* :spawn)
         (server (micros/backend:create-socket host port)))
    (setf *server-socket* server)
    (format t "~&CL-RPC server listening on ~A:~A~%" host port)
    (when *static-dir*
      (format t "~&Serving static files from ~A~%" *static-dir*))
    (finish-output)
    (setf *server-thread*
          (micros/backend:spawn
           (lambda ()
             (unwind-protect
                  (loop
                    (unless *server-socket* (return))
                    (handler-case
                        (let ((stream (micros/backend:accept-connection
                                       server :external-format nil)))
                          (micros/backend:spawn
                           (lambda () (handle-connection stream))
                           :name "cl-rpc-connection"))
                      (error (c)
                        (when *server-socket*
                          (format *error-output* "Accept error: ~A~%" c))
                        (return))))
               (format t "~&CL-RPC server stopped.~%")))
           :name "cl-rpc-server"))
    (values server *server-thread*)))

(defun stop-server ()
  "Stop the running server."
  (when *server-socket*
    (handler-case
        (micros/backend:close-socket *server-socket*)
      (error () nil))
    (setf *server-socket* nil))
  (when *server-thread*
    (handler-case
        (micros/backend:kill-thread *server-thread*)
      (error () nil))
    (setf *server-thread* nil))
  (format t "~&CL-RPC server stopped.~%")
  (values))
