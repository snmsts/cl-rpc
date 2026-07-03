;;;; mcp.lisp — Model Context Protocol (Streamable HTTP) veneer.
;;;;
;;;; MCP is JSON-RPC 2.0, the same family cl-rpc already speaks; the only new
;;;; things are a self-describing tool catalog (tools/list) and the standard
;;;; transport (a plain HTTP POST endpoint, /mcp). This module handles one MCP
;;;; message and returns the JSON-RPC response string (or NIL for a
;;;; notification). The server wires POST /mcp to here; `eval` reuses the same
;;;; read/eval/print cl-rpc uses over WebSocket, so the two protocols share one
;;;; engine. Single responses go back as application/json — the SSE streaming
;;;; mode (for server-initiated messages) is not needed for request/response
;;;; tool calls and is left for later.

(in-package #:cl-rpc/mcp)

;; Echoed back to the client on initialize when it does not request a version.
(defparameter *protocol-version* "2025-06-18")
(defparameter *server-name* "cl-rpc")
(defparameter *server-version* "0.1.0")

(defun obj (&rest kv)
  "A JSON object (hash-table) from a plist of string-key / value pairs."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun gh (table key)
  (and (hash-table-p table) (gethash key table)))

(defun eval-tool ()
  (obj "name" "eval"
       "description"
       (concatenate 'string
        "Evaluate a Common Lisp form inside the attached process and return the "
        "printed result. Runs in the target's live image, so use it to inspect or "
        "change the running process's state, call its functions, or reach the .NET "
        "host via the dotnet: package.")
       "inputSchema"
       (obj "type" "object"
            "properties"
            (obj "code" (obj "type" "string"
                             "description" "A single Common Lisp form to evaluate.")
                 "package" (obj "type" "string"
                                "description" "Package to read/eval in (default CL-USER)."))
            "required" (vector "code"))))

(defun mcp-eval (code package-name)
  "Evaluate CODE in PACKAGE-NAME. Returns (values text is-error-p)."
  (if (not (stringp code))
      (values "; error: missing \"code\" argument" t)
      (let ((*package* (or (and (stringp package-name)
                                (find-package (string-upcase package-name)))
                           (find-package :cl-user)))
            ;; The connection thread's *standard-output* is the client socket
            ;; (micros binds it SLIME-style). Isolate eval output to a string so
            ;; compile notes / prints never leak onto the wire and corrupt the
            ;; HTTP response. (Streaming stdout back is a later feature.)
            (*standard-output* (make-string-output-stream))
            (*error-output*    (make-string-output-stream))
            (*trace-output*    (make-string-output-stream)))
        (handler-case
            (let ((vals (multiple-value-list (eval (read-from-string code)))))
              (values (if vals
                          (format nil "~{~A~^~%~}" (mapcar #'prin1-to-string vals))
                          "; No values")
                      nil))
          (serious-condition (c)
            (values (format nil "~A" c) t))))))

(defun ok (id result)
  (json-stringify (obj "jsonrpc" "2.0" "id" id "result" result)))

(defun err (id code message)
  (json-stringify (obj "jsonrpc" "2.0" "id" id "error" (obj "code" code "message" message))))

(defun notification-p (method)
  (and (stringp method)
       (>= (length method) 14)
       (string= method "notifications/" :end1 14)))

(defun handle-mcp-message (json-string)
  "Dispatch one MCP JSON-RPC message. Returns the response JSON string, or NIL
for a notification (which gets no response body)."
  (let* ((req    (json-parse json-string))
         (method (gh req "method"))
         (id     (gh req "id"))
         (params (gh req "params")))
    (cond
      ((not (stringp method)) (and id (err id -32600 "Invalid Request")))
      ((notification-p method) nil)             ; e.g. notifications/initialized
      ((string= method "initialize")
       (ok id (obj "protocolVersion" (or (gh params "protocolVersion") *protocol-version*)
                   "capabilities" (obj "tools" (obj))
                   "serverInfo" (obj "name" *server-name* "version" *server-version*))))
      ((string= method "tools/list")
       (ok id (obj "tools" (vector (eval-tool)))))
      ((string= method "tools/call")
       (let ((name (gh params "name"))
             (args (gh params "arguments")))
         (if (equal name "eval")
             (multiple-value-bind (text error-p) (mcp-eval (gh args "code") (gh args "package"))
               (ok id (if error-p
                          (obj "content" (vector (obj "type" "text" "text" text)) "isError" t)
                          ;; isError defaults to false in MCP; omit it (the JSON
                          ;; writer has no false literal).
                          (obj "content" (vector (obj "type" "text" "text" text))))))
             (and id (err id -32602 (format nil "Unknown tool: ~A" name))))))
      (t (and id (err id -32601 (format nil "Method not found: ~A" method)))))))
