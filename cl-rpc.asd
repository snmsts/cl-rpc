(defsystem "cl-rpc"
  :description "WebSocket + JSON-RPC 2.0 REPL backend for Common Lisp"
  :version "0.1.0"
  :depends-on ("micros")
  :serial t
  :components ((:file "src/packages")
               (:file "src/websocket")
               (:file "src/json-rpc")
               (:file "src/backend")
               (:file "src/handlers")
               (:file "src/server")))
