(defpackage #:cl-rpc/websocket
  (:use #:cl)
  (:export #:handshake
           #:read-http-request-lines
           #:extract-header
           #:read-frame
           #:write-text-frame
           #:write-pong-frame
           #:write-close-frame))

(defpackage #:cl-rpc/json-rpc
  (:use #:cl)
  (:export #:parse-request
           #:request-id
           #:request-method
           #:request-params
           #:send-response
           #:send-error
           #:send-notification
           #:*debug-log*
           #:*real-error-output*
           #:%log))

(defpackage #:cl-rpc/backend
  (:use #:cl)
  (:export #:backend-eval
           #:backend-completions
           #:backend-set-package
           #:backend-debugger-info
           #:backend-invoke-restart
           #:backend-abort
           #:backend-macroexpand
           #:backend-describe
           #:backend-find-definitions
           #:backend
           #:shortest-package-name
           #:symbol-kind))

(defpackage #:cl-rpc/handlers
  (:use #:cl #:cl-rpc/json-rpc #:cl-rpc/backend #:micros/gray)
  (:export #:dispatch-request
           #:make-connection-state
           #:connection-state
           #:send-welcome))

(defpackage #:cl-rpc
  (:use #:cl)
  (:export #:start-server
           #:stop-server))
