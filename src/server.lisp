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

(defun write-http-response (stream status-code status-text content-type body-octets
                            &optional extra-headers)
  "Write an HTTP/1.1 response to a binary stream.
EXTRA-HEADERS is a list of (name . value) added after Content-Length."
  (let ((crlf (coerce '(13 10) '(vector (unsigned-byte 8)))))
    (flet ((write-header-line (str)
             (write-sequence (string-to-ascii-octets str) stream)
             (write-sequence crlf stream)))
      (write-header-line (format nil "HTTP/1.1 ~D ~A" status-code status-text))
      (write-header-line (format nil "Content-Type: ~A" content-type))
      (write-header-line (format nil "Content-Length: ~D" (length body-octets)))
      (loop for (name . value) in extra-headers
            do (write-header-line (format nil "~A: ~A" name value)))
      (write-header-line "Connection: close")
      (write-sequence crlf stream)
      (write-sequence body-octets stream)
      (finish-output stream))))

(defun send-404 (stream)
  (write-http-response stream 404 "Not Found" "text/plain"
                       (micros/backend:string-to-utf8 "404 Not Found")))

(defun send-status (stream code text &optional extra-headers)
  (write-http-response stream code text "text/plain"
                       (micros/backend:string-to-utf8 (format nil "~D ~A" code text))
                       extra-headers))

;;; -----------------------------------------------------------------------
;;; Access control
;;; -----------------------------------------------------------------------
;;; Three independent gates, set by start-server. A request must pass all of them.
;;;   *allowed-origins* — checked on every request (WebSocket handshake, /mcp, static).
;;;   *allowed-hosts*   — likewise; stops DNS rebinding.
;;;   *auth-token*      — WebSocket: the first text frame; /mcp: Authorization: Bearer.
;;; Browser-page JavaScript always sends Origin and cannot remove it, so the default
;;; *allowed-origins* (nil: no Origin allowed) keeps every web page out, while CLI and
;;; MCP clients, which send none, get in.

(defvar *allowed-origins* nil
  "Origins allowed to connect: T = don't check; a list = a request with an Origin
header must match one of them (case-insensitively). A request without Origin always
passes, so NIL (the empty list) admits only clients that send none.")

(defvar *allowed-hosts* t
  "Host header values allowed: T = don't check; a list = the Host header must match
one of them (case-insensitively). NIL admits nobody.")

(defvar *auth-token* nil
  "NIL = no authentication. A string = the secret a WebSocket client must send as its
first text frame, and an /mcp request must carry as Authorization: Bearer <token>.")

(defun loopback-hosts (port)
  "Host header values naming this machine's loopback interface on PORT."
  (list (format nil "127.0.0.1:~D" port)
        (format nil "localhost:~D" port)
        (format nil "[::1]:~D" port)))

(defun loopback-origins (port)
  "Origins of pages served from this machine's loopback interface on PORT, e.g. the
bundled browser client served via :static-dir."
  (mapcar (lambda (h) (format nil "http://~A" h)) (loopback-hosts port)))

(defun %allowed-p (value allowed)
  (or (eq allowed t)
      (and value (member value allowed :test #'string-equal) t)))

(defun request-admitted-p (lines)
  "Apply the Origin and Host gates to a request's header LINES. Logs a rejection."
  (let ((origin (cl-rpc/websocket:extract-header lines "Origin"))
        (host   (cl-rpc/websocket:extract-header lines "Host")))
    (cond ((and origin (not (%allowed-p origin *allowed-origins*)))
           (cl-rpc/json-rpc::%log "~&[reject] Origin ~A not allowed~%" origin)
           nil)
          ((not (%allowed-p host *allowed-hosts*))
           (cl-rpc/json-rpc::%log "~&[reject] Host ~A not allowed~%" host)
           nil)
          (t t))))

(defun bearer-token-p (lines)
  "True when no token is required or the request carries Authorization: Bearer <token>."
  (or (null *auth-token*)
      (let ((auth (cl-rpc/websocket:extract-header lines "Authorization")))
        (and auth
             (> (length auth) 7)
             (string-equal "Bearer " auth :end2 7)
             (string= *auth-token* (string-trim " " (subseq auth 7)))))))

(defun read-request-body (stream lines)
  "Read the Content-Length body of an HTTP request as a UTF-8 string, or NIL."
  (let* ((cl  (cl-rpc/websocket:extract-header lines "Content-Length"))
         (len (and cl (ignore-errors (parse-integer cl :junk-allowed t)))))
    (when (and len (plusp len))
      (let ((buf (make-array len :element-type '(unsigned-byte 8)))
            (pos 0))
        (loop while (< pos len)
              for n = (read-sequence buf stream :start pos)
              while (> n pos)
              do (setf pos n))
        (micros/backend:utf8-to-string (if (= pos len) buf (subseq buf 0 pos)))))))

(defun handle-mcp-http (stream lines)
  "MCP Streamable HTTP endpoint: the POST body is one JSON-RPC message; reply
with the JSON-RPC response as application/json (or 202 Accepted with no body
for a notification). Shares cl-rpc/mcp's dispatch, whose `eval` is the same
read/eval/print used over WebSocket."
  (unless (bearer-token-p lines)
    (cl-rpc/json-rpc::%log "~&[reject] /mcp without a valid bearer token~%")
    (send-status stream 401 "Unauthorized" '(("WWW-Authenticate" . "Bearer")))
    (return-from handle-mcp-http))
  (let* ((body (read-request-body stream lines))
         (resp (and body (cl-rpc/mcp:handle-mcp-message body))))
    (if resp
        (write-http-response stream 200 "OK" "application/json"
                             (micros/backend:string-to-utf8 resp))
        (write-http-response stream 202 "Accepted" "application/json"
                             (micros/backend:string-to-utf8 "")))))

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
  "Perform the WebSocket handshake and run the frame receive loop.
When *auth-token* is set, the first text frame must be exactly the token; anything
else closes the connection. The welcome is sent only after that."
  (cl-rpc/websocket:handshake stream :lines lines)
  (let ((state (cl-rpc/handlers:make-connection-state
                :backend   (make-instance 'cl-rpc/backend:backend)
                :ws-stream stream)))
    (when *auth-token*
      (multiple-value-bind (type payload) (cl-rpc/websocket:read-frame stream)
        (unless (and (eq type :text) (string= payload *auth-token*))
          (cl-rpc/json-rpc::%log "~&[reject] bad or missing auth token; closing~%")
          (cl-rpc/websocket:write-close-frame stream)
          (return-from handle-websocket-connection))))
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
          ((not (request-admitted-p lines))
           (send-status stream 403 "Forbidden"))
          ((and upgrade (string-equal upgrade "websocket"))
           (handle-websocket-connection stream lines))
          (t
           (multiple-value-bind (method path)
               (parse-request-line (or (car lines) ""))
             (cond
               ;; MCP (Streamable HTTP): same JSON-RPC engine, another endpoint.
               ((and method (string= method "POST") (string= path "/mcp"))
                (handle-mcp-http stream lines))
               ;; No server-to-client SSE stream: the spec's answer is 405.
               ((equal path "/mcp")
                (send-status stream 405 "Method Not Allowed" '(("Allow" . "POST"))))
               ((and method (string= method "GET"))
                (handle-http-get stream path))
               (t (send-404 stream)))))))
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

(defun start-server (&key (port 7654) (host "127.0.0.1") debug static-dir
                          allowed-origins (allowed-hosts (loopback-hosts port)) token)
  "Start the WebSocket + JSON-RPC server.
   port:            port to listen on (default 7654)
   host:            address to bind to (default \"127.0.0.1\")
   debug:           nil=disabled, t=log to *error-output*, stream=log to that stream
   static-dir:      directory to serve static files from (nil disables static serving)
   allowed-origins: t = don't check; a list = a request carrying Origin must match one.
                    Default nil: only requests without Origin (i.e. no web page) pass.
                    The bundled browser client needs (loopback-origins port).
   allowed-hosts:   t = don't check; a list = the Host header must match one; nil = nobody.
                    Default (loopback-hosts port).
   token:           nil = no authentication (default). A string: WebSocket clients send it
                    as their first text frame, /mcp requests as Authorization: Bearer <token>."
  (setf cl-rpc/json-rpc:*debug-log* debug)
  (setf *allowed-origins* allowed-origins
        *allowed-hosts*   allowed-hosts
        *auth-token*      token)
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
