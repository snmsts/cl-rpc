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
(cl-rpc:start-server :port 7654 :static-dir "/path/to/ws-lisp/client/browser"
                     :allowed-origins (cl-rpc:loopback-origins 7654))
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
| `:allowed-origins` | `nil` | `t` = don't check. A list = a request carrying an `Origin` header must match one of them. Requests without `Origin` always pass, so the default `nil` admits CLI and MCP clients but no web page. |
| `:allowed-hosts` | `(loopback-hosts port)` | `t` = don't check. A list = the `Host` header must match one of them; `nil` admits nobody. |
| `:token` | `nil` | `nil` = no authentication. A string: a WebSocket client must send it as its first text frame, and an `/mcp` request must carry `Authorization: Bearer <token>`. |

### Access control

A running image behind cl-rpc is an eval endpoint, so by default only programs that
are not web pages can reach it. Every request (WebSocket handshake, `/mcp`, static
files) passes three independent gates, and must pass all of them:

- **Origin.** Browser-page JavaScript always sends `Origin` and cannot remove it,
  so with the default `:allowed-origins nil` no web page can connect. The bundled
  browser client is itself a web page; serve it with
  `:allowed-origins (cl-rpc:loopback-origins port)`.
- **Host.** The `Host` header must name the loopback interface (`127.0.0.1:<port>`,
  `localhost:<port>`, `[::1]:<port>`). This stops DNS rebinding. Behind a reverse
  proxy, pass the names it forwards, or `t`.
- **Token** (opt-in). Stops other local processes. An MCP client passes it as a
  header, e.g. `claude mcp add --transport http lisp http://127.0.0.1:7654/mcp
  --header "Authorization: Bearer <token>"`.

A request refused by Origin or Host gets `403`; an `/mcp` request without the
token gets `401`; a WebSocket client that sends anything but the token first is
disconnected.

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
See [Access control](#access-control) for what cl-rpc checks itself; for
anything more (TLS, user accounts), put a reverse proxy in front.

## MCP endpoint

The same server also speaks [MCP](https://modelcontextprotocol.io/) (Model
Context Protocol) over Streamable HTTP at `POST /mcp` — MCP is JSON-RPC 2.0, the
same family cl-rpc already speaks, so it reuses the existing eval engine. Point
any MCP client at `http://<host>:<port>/mcp` and it gets one tool, `eval`, that
evaluates a Common Lisp form inside the live image and returns the printed
result. This lets an LLM agent inspect and drive a running Lisp process the same
way a human uses the REPL.

```
POST /mcp   {"jsonrpc":"2.0","id":1,"method":"initialize", ...}
POST /mcp   {"jsonrpc":"2.0","id":2,"method":"tools/list"}
POST /mcp   {"jsonrpc":"2.0","id":3,"method":"tools/call",
             "params":{"name":"eval","arguments":{"code":"(+ 1 2)"}}}
```

Each POST body is a single JSON-RPC message; the response comes back as
`application/json`. eval output (stdout/compile notes) is isolated from the
transport so it cannot corrupt the response. `GET /mcp` answers `405`: there is
no server-to-client stream. The [Access control](#access-control) gates apply here
too.

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

JSON serialization uses a minimal inline implementation (no external library)
and writes directly to the WebSocket stream. There is no intermediate
s-expression representation; eval return values are captured with
`prin1-to-string` and stored as JSON strings in one step.

## License

MIT
