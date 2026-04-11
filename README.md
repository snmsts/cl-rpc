# cl-rpc

WebSocket + JSON-RPC 2.0 REPL backend for Common Lisp.

## Overview

cl-rpc exposes a running Lisp image as a JSON-RPC 2.0 service over WebSocket.
It solves the problem of connecting non-Lisp frontends (web browsers, editors,
CLI tools written in Go, etc.) to a live Lisp REPL without requiring Swank or
SLIME. Anyone building a Lisp REPL UI — web applications, editor plugins, or
command-line tools — can use cl-rpc as the backend.

## Features

- WebSocket transport, JSON-RPC 2.0 protocol
- Eval with streaming stdout / stderr / trace output
- Tab completion, symbol describe, apropos
- Cross-reference (callers, callees, references)
- Macroexpand (single and full)
- Find definitions
- Interactive debugger (restarts, backtrace)
- Interrupt running evaluations
- Trace / untrace
- Thread listing
- Protocol versioning via `welcome` notification on connect
- Static file serving for web UIs (same port, optional)
- Reference clients: browser (`www/index.html`) and Go CLI (`client/go/`)

## Requirements

- SBCL (primary target; other implementations may work)
- [Quicklisp](https://www.quicklisp.org/)
- [qlot](https://github.com/fukamachi/qlot) — manages the git dependency on [micros](https://github.com/lem-project/micros)

## Installation

```bash
git clone https://github.com/snmsts/cl-rpc
cd cl-rpc
qlot install
```

Then start a Lisp session inside the qlot environment:

```bash
qlot exec ros run
# or: qlot exec sbcl --load ...
```

```lisp
(asdf:load-system :cl-rpc)
```

## Quick Start

Run these examples inside a `qlot exec` session (see [Installation](#installation)).

Start a server on the default port:

```lisp
(asdf:load-system :cl-rpc)
(cl-rpc:start-server :port 7654)
```

Start with the bundled web client:

```lisp
(cl-rpc:start-server :port 7654 :static-dir "/path/to/ws-lisp/client/browser")
```

Then open `http://localhost:7654` in a browser.

To stop the server:

```lisp
(cl-rpc:stop-server)
```

### `start-server` keyword arguments

| Argument | Default | Description |
|---|---|---|
| `:port` | `7654` | Port to listen on |
| `:host` | `"127.0.0.1"` | Address to bind to |
| `:debug` | `nil` | `t` logs to `*error-output*`; pass a stream to redirect |
| `:static-dir` | `nil` | Directory to serve static files from; `nil` disables |

## Reference Clients

**Browser — `client/browser/index.html`**

A self-contained browser REPL. Features a CodeMirror editor with syntax
highlighting, streaming output display, and a debugger UI for selecting
restarts and inspecting backtraces. Served automatically when `:static-dir`
points at the `client/browser/` directory.

**Go CLI — `client/go/`**

A terminal REPL written in Go. Supports readline-style editing, tab
completion, and the interactive debugger. Useful for connecting to a remote
Lisp image from the command line without a browser.

Build and run:

```
cd client/go
go build -o cl-rpc-client .
./cl-rpc-client -host localhost -port 7654
```

## Protocol

The full protocol specification is in [`docs/protocol.md`](docs/protocol.md).
The core flow is: connect via
WebSocket → receive a `welcome` notification from the server (carrying
`protocol-version`, `implementation`, and `implementation-version`) → begin
sending JSON-RPC 2.0 request objects. Notifications such as `output`, `debug`,
and `debug-return` are pushed from the server asynchronously at any time.
Authentication is not handled by cl-rpc itself; delegate to a reverse proxy
(nginx Basic Auth, JWT, etc.) if needed.

## Architecture

```
Browser / CLI client
        |
        |  WebSocket  (JSON-RPC 2.0, UTF-8 text frames)
        |
   cl-rpc server  (Common Lisp)
        |
        |  direct function calls — JSON written straight to stream
        |
   micros backend  (per-implementation interface)
        |
   Lisp image  (SBCL)
```

JSON serialization uses `com.inuoe.jzon` and writes directly to the WebSocket
stream. There is no intermediate s-expression representation; eval return
values are captured with `prin1-to-string` and stored as JSON strings in one
step.

## License

MIT
