# CL-RPC Protocol Specification

**Version:** 1.0  
**Transport:** WebSocket (RFC 6455) + JSON-RPC 2.0

---

## Table of Contents

1. [Overview](#1-overview)
2. [Connection Lifecycle](#2-connection-lifecycle)
3. [Message Format](#3-message-format)
4. [Server-to-Client Notifications](#4-server-to-client-notifications)
5. [Client-to-Server Methods](#5-client-to-server-methods)
   - 5.1 [Evaluation](#51-evaluation)
   - 5.2 [Environment](#52-environment)
   - 5.3 [Navigation](#53-navigation)
   - 5.4 [Code Tools](#54-code-tools)
   - 5.5 [Debugging](#55-debugging)
   - 5.6 [Meta](#56-meta)
6. [Debugger Flow](#6-debugger-flow)
7. [Error Codes](#7-error-codes)
8. [Symbol Representation](#8-symbol-representation)
9. [Kind Values](#9-kind-values)

---

## 1. Overview

CL-RPC is a WebSocket-based REPL backend for Common Lisp. It exposes a JSON-RPC 2.0 API over a persistent WebSocket connection, allowing any client — browser, CLI tool, editor plugin, or language-agnostic script — to evaluate Lisp code, navigate definitions, inspect symbols, and interact with the debugger.

CL-RPC is designed as a replacement for SWANK/SLynk/Micros for contexts where JSON and WebSocket are preferable to the proprietary S-expression wire format. The server is implementation-agnostic; the reference implementation targets SBCL.

**Key design properties:**

- All messages are UTF-8 text WebSocket frames.
- The server never authenticates connections; authentication must be handled at the reverse-proxy layer (e.g., nginx Basic Auth or JWT).
- `eval` runs in a dedicated thread per request, enabling concurrent operation and interrupt support.
- Output (stdout, stderr, trace) is streamed to the client as it is produced via asynchronous `output` notifications.

---

## 2. Connection Lifecycle

```
Client                                  Server
  |                                       |
  |------- TCP + WebSocket handshake ---->|
  |                                       |
  |<------ notification: welcome ---------|  (server sends immediately)
  |                                       |
  |------- request: eval ------------->   |
  |<------ notification: output --------- |  (zero or more, interleaved)
  |<------ response: eval result -------- |
  |                                       |
  |------- request: capabilities -------> |
  |<------ response: capabilities ------- |
  |                                       |
  |------- WebSocket close frame -------> |
  |<------ WebSocket close frame -------- |
```

1. The client opens a WebSocket connection to the server.
2. Immediately after the handshake, the server sends a `welcome` notification. The client **must** wait for this notification before sending any requests.
3. The client sends JSON-RPC requests and receives JSON-RPC responses and notifications.
4. Either side may close the connection at any time using a standard WebSocket close frame.

---

## 3. Message Format

All messages follow JSON-RPC 2.0. Each message is a single WebSocket text frame containing a UTF-8-encoded JSON object.

### Request (client to server)

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "method-name",
  "params": { ... }
}
```

- `id`: a positive integer chosen by the client. Must be unique among in-flight requests.
- `params`: an object (never an array). May be omitted for methods that take no parameters.

### Response (server to client)

**Success:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { ... }
}
```

**Error:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32000,
    "message": "Unbound variable: X"
  }
}
```

### Notification (server to client)

Notifications are messages the server sends without a corresponding client request. They have no `id` field.

```json
{
  "jsonrpc": "2.0",
  "method": "notification-name",
  "params": { ... }
}
```

---

## 4. Server-to-Client Notifications

Notifications are sent by the server at any time on the connection, not in response to a specific request.

### 4.1 `welcome`

Sent immediately after the WebSocket handshake completes. The client should not send requests before receiving this notification.

**Params:**

| Field | Type | Description |
|---|---|---|
| `protocol-version` | string | Protocol version, currently `"1.0"` |
| `implementation` | string | Lisp implementation name (e.g., `"SBCL"`) |
| `implementation-version` | string | Lisp implementation version string |

**Example:**

```json
{
  "jsonrpc": "2.0",
  "method": "welcome",
  "params": {
    "protocol-version": "1.0",
    "implementation": "SBCL",
    "implementation-version": "2.6.1"
  }
}
```

---

### 4.2 `output`

Sent whenever output is produced during evaluation. Stdout and stderr are flushed line by line; output is buffered and flushed on each newline. Trace output (from `trace`/`untrace`) is sent on the `"trace"` target.

**Params:**

| Field | Type | Description |
|---|---|---|
| `text` | string | The output text (may contain newlines) |
| `target` | string | One of `"stdout"`, `"stderr"`, `"trace"` |

**Example:**

```json
{
  "jsonrpc": "2.0",
  "method": "output",
  "params": {
    "text": "Hello, world!\n",
    "target": "stdout"
  }
}
```

---

### 4.3 `debug`

Sent when an unhandled condition causes the Lisp debugger to be entered during an `eval`. The eval response is **not** sent at this point; the client must interact with the debugger via `invoke-restart` or `abort`, after which a `debug-return` notification is sent and the eval response follows.

**Params:**

| Field | Type | Description |
|---|---|---|
| `level` | integer | Debugger nesting level (starts at 1) |
| `condition` | string | Human-readable description of the condition |
| `restarts` | array | Available restarts (see below) |
| `frames` | array | Stack frames (see below) |

**Restart object:**

| Field | Type | Description |
|---|---|---|
| `index` | integer | Zero-based index used with `invoke-restart` |
| `name` | string | Restart name (e.g., `"ABORT"`, `"CONTINUE"`) |
| `description` | string | Human-readable description of what the restart does |

**Frame object:**

| Field | Type | Description |
|---|---|---|
| `index` | integer | Zero-based stack frame index |
| `description` | string | Human-readable frame description |

**Example:**

```json
{
  "jsonrpc": "2.0",
  "method": "debug",
  "params": {
    "level": 1,
    "condition": "Unbound variable: X",
    "restarts": [
      {"index": 0, "name": "CONTINUE", "description": "Retry using X"},
      {"index": 1, "name": "ABORT",    "description": "Return to top level"}
    ],
    "frames": [
      {"index": 0, "description": "((LAMBDA NIL) ...)"},
      {"index": 1, "description": "SB-INT:SIMPLE-EVAL-IN-LEXENV"}
    ]
  }
}
```

---

### 4.4 `debug-return`

Sent after the debugger exits, either because a restart was invoked or `abort` was called. After this notification the `eval` response (result or error) will arrive.

**Params:**

| Field | Type | Description |
|---|---|---|
| `level` | integer | The debugger level that was exited |

**Example:**

```json
{
  "jsonrpc": "2.0",
  "method": "debug-return",
  "params": {"level": 1}
}
```

---

## 5. Client-to-Server Methods

All methods use the JSON-RPC request format. Optional fields may be omitted from `params`; the server applies documented defaults.

### 5.1 Evaluation

#### `eval`

Evaluate a string of Lisp code. Runs in a dedicated thread. Output is streamed via `output` notifications as it is produced. Returns the printed representations of all result values.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `code` | string | yes | The Lisp form(s) to evaluate, as a string |
| `package` | string | no | Package to evaluate in. Default: `"CL-USER"` |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `values` | array of string | `prin1-to-string` of each returned value. Empty array for zero-values. |
| `package` | string | The current package name after evaluation |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eval",
  "params": {"code": "(values 1 :hello)", "package": "cl-user"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "values": ["1", ":HELLO"],
    "package": "cl-user"
  }
}
```

If evaluation enters the debugger, the response is **deferred**. The server sends a `debug` notification instead. See [Section 6](#6-debugger-flow).

---

#### `interrupt`

Interrupt a currently running `eval`. Injects an asynchronous signal into the eval thread. The interrupted `eval` will return an error response with code `-32002`.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | integer | no | Reserved for future use (currently ignored) |

**Result fields:** empty object `{}`

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "interrupt",
  "params": {}
}

// response
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {}
}
```

If there is no active eval thread, returns an error with code `-32000`.

---

### 5.2 Environment

#### `completions`

Return completion candidates for a symbol prefix.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `prefix` | string | yes | Symbol prefix to complete |
| `package` | string | no | Package context. Default: `"CL-USER"` |
| `internal` | boolean | no | If `true`, include internal (unexported) symbols |
| `limit` | integer | no | Maximum number of candidates to return |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `candidates` | array | Completion candidates (see below) |

**Candidate object:**

| Field | Type | Description |
|---|---|---|
| `label` | string | The completed symbol name |
| `kind` | string | Symbol kind (see [Section 9](#9-kind-values)) |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "completions",
  "params": {"prefix": "string-u", "package": "cl-user"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "candidates": [
      {"label": "string-upcase", "kind": "function"}
    ]
  }
}
```

---

#### `set-package`

Change the current package for subsequent `eval` calls on this connection.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Package name to switch to |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `package` | string | Canonical name of the new current package |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "set-package",
  "params": {"name": "my-app"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {"package": "my-app"}
}
```

Returns error code `-32001` if the package does not exist.

---

#### `describe`

Return documentation and metadata for a symbol.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `symbol` | string | yes | Symbol name |
| `package` | string | no | Package context for resolving the symbol. Default: `"CL-USER"` |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Canonical symbol name (uppercased) |
| `type` | string | Symbol kind (see [Section 9](#9-kind-values)) |
| `package` | string | Home package of the symbol |
| `args` | string or null | Argument list string, for functions and macros only |
| `docstring` | string or null | Documentation string, or `null` if none |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "describe",
  "params": {"symbol": "mapcar", "package": "cl-user"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "name": "MAPCAR",
    "type": "function",
    "package": "COMMON-LISP",
    "args": "(FUNCTION LIST &REST MORE-LISTS)",
    "docstring": "Apply FUNCTION to successive elements of LIST."
  }
}
```

---

#### `apropos`

Search for symbols whose names contain a pattern string.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `pattern` | string | yes | Substring to search for |
| `package` | string | no | If given, restrict search to this package |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `symbols` | array | Matching symbols (see below) |

**Symbol object:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Symbol name (uppercased) |
| `package` | string or null | Home package, or `null` for uninterned symbols |
| `kind` | string | Symbol kind (see [Section 9](#9-kind-values)) |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "apropos",
  "params": {"pattern": "nreverse"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "symbols": [
      {"name": "NREVERSE",  "package": "COMMON-LISP", "kind": "function"},
      {"name": "NRECONC",   "package": "COMMON-LISP", "kind": "function"}
    ]
  }
}
```

---

### 5.3 Navigation

#### `find-definitions`

Return the source locations where a symbol is defined.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `symbol` | string | yes | Symbol name |
| `package` | string | no | Package context. Default: `"CL-USER"` |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `definitions` | array | Definition locations (see below) |

**Definition object:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Qualified name of the definition |
| `type` | string | Definition kind (e.g., `"function"`, `"class"`) |
| `file` | string | Absolute server-local path to the source file |
| `position` | integer | Byte offset into the source file |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "find-definitions",
  "params": {"symbol": "my-function", "package": "my-app"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "definitions": [
      {
        "name": "MY-APP:MY-FUNCTION",
        "type": "function",
        "file": "/home/user/src/my-app.lisp",
        "position": 1234
      }
    ]
  }
}
```

---

#### `xref-callers`

Return a list of functions that call a given symbol.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `symbol` | string | yes | Target symbol name |
| `package` | string | no | Package context. Default: `"CL-USER"` |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `xrefs` | array | Cross-reference entries (see below) |

**Xref object:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Qualified name of the referring definition |
| `file` | string | Source file path (may be absent if not available) |
| `position` | integer | Byte offset (may be absent if not available) |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "xref-callers",
  "params": {"symbol": "mapcar", "package": "cl-user"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "xrefs": [
      {"name": "MY-APP:PROCESS-LIST", "file": "/home/user/src/my-app.lisp", "position": 456}
    ]
  }
}
```

---

#### `xref-callees`

Return a list of functions called by a given symbol.

**Request params:** same as `xref-callers`.

**Result fields:** same as `xref-callers`.

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "xref-callees",
  "params": {"symbol": "process-list", "package": "my-app"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "xrefs": [
      {"name": "COMMON-LISP:MAPCAR", "file": "/usr/lib/sbcl/src/code/list.lisp", "position": 789}
    ]
  }
}
```

---

#### `xref-references`

Return a list of code locations that reference a given symbol (primarily useful for global variables).

**Request params:** same as `xref-callers`.

**Result fields:** same as `xref-callers`.

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "xref-references",
  "params": {"symbol": "*my-global*", "package": "my-app"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 10,
  "result": {
    "xrefs": [
      {"name": "MY-APP:RESET", "file": "/home/user/src/my-app.lisp", "position": 2048}
    ]
  }
}
```

---

### 5.4 Code Tools

#### `macroexpand`

Expand a macro form. By default performs a single-level expansion (`macroexpand-1`); pass `"all": true` for full recursive expansion.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `code` | string | yes | The macro form as an S-expression string |
| `package` | string | no | Package context. Default: `"CL-USER"` |
| `all` | boolean | no | If `true`, fully expand all macros recursively. Default: `false` |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `expansion` | string | Pretty-printed expansion result |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "macroexpand",
  "params": {"code": "(when t (print 1))", "package": "cl-user"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": {
    "expansion": "(IF T\n    (PROGN (PRINT 1)))"
  }
}
```

---

### 5.5 Debugging

#### `invoke-restart`

Select a restart while the debugger is active. Must only be called after receiving a `debug` notification.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `index` | integer | yes | Zero-based index of the restart from the `debug` notification's `restarts` array |
| `level` | integer | no | Debugger level (reserved; currently ignored) |
| `value` | string | no | S-expression string to pass as an argument to the restart (e.g., for `USE-VALUE`) |

**Result fields:** empty object `{}`

**Example (simple restart):**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 12,
  "method": "invoke-restart",
  "params": {"index": 0}
}

// response
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {}
}
```

**Example (restart with value):**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 13,
  "method": "invoke-restart",
  "params": {"index": 0, "value": "42"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": {}
}
```

Returns error code `-32000` with message `"No active debugger session"` if no debugger is active.

---

#### `abort`

Abort from the active debugger session without selecting a restart.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `level` | integer | no | Debugger level to abort (reserved; currently ignored) |

**Result fields:** empty object `{}`

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 14,
  "method": "abort",
  "params": {}
}

// response
{
  "jsonrpc": "2.0",
  "id": 14,
  "result": {}
}
```

Returns error code `-32000` with message `"No active debugger session"` if no debugger is active.

---

#### `trace`

Enable tracing for a function. Trace output will be sent as `output` notifications with `"target": "trace"`.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `symbol` | string | yes | Qualified symbol name of the function to trace |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `message` | string | Confirmation message |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 15,
  "method": "trace",
  "params": {"symbol": "my-app:process-list"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 15,
  "result": {"message": "MY-APP:PROCESS-LIST is now traced."}
}
```

---

#### `untrace`

Disable tracing for a function, or all traced functions if `symbol` is omitted.

**Request params:**

| Field | Type | Required | Description |
|---|---|---|---|
| `symbol` | string | no | Qualified symbol name to untrace. Omit to untrace all traced functions. |

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `message` | string | Confirmation message |

**Example (single function):**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 16,
  "method": "untrace",
  "params": {"symbol": "my-app:process-list"}
}

// response
{
  "jsonrpc": "2.0",
  "id": 16,
  "result": {"message": "my-app:process-list is now untraced."}
}
```

**Example (untrace all):**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 17,
  "method": "untrace",
  "params": {}
}

// response
{
  "jsonrpc": "2.0",
  "id": 17,
  "result": {"message": "All functions untraced."}
}
```

---

#### `threads`

List all live threads in the Lisp image.

**Request params:** none (empty object or omitted)

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `threads` | array | Thread entries (see below) |

**Thread object:**

| Field | Type | Description |
|---|---|---|
| `id` | integer | Implementation thread ID |
| `name` | string | Thread name |
| `status` | string | Thread status string (e.g., `"Running"`, `"Sleeping"`) |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 18,
  "method": "threads",
  "params": {}
}

// response
{
  "jsonrpc": "2.0",
  "id": 18,
  "result": {
    "threads": [
      {"id": 1, "name": "main thread",    "status": "Running"},
      {"id": 2, "name": "cl-rpc-eval-17", "status": "Running"}
    ]
  }
}
```

---

### 5.6 Meta

#### `capabilities`

Query which methods and notifications the server supports. Useful for feature detection when the protocol version is not sufficient.

**Request params:** none (empty object or omitted)

**Result fields:**

| Field | Type | Description |
|---|---|---|
| `methods` | array of string | All supported method names |
| `notifications` | array of string | All notification names the server may send |

**Example:**

```json
// request
{
  "jsonrpc": "2.0",
  "id": 19,
  "method": "capabilities",
  "params": {}
}

// response
{
  "jsonrpc": "2.0",
  "id": 19,
  "result": {
    "methods": [
      "eval", "completions", "set-package",
      "macroexpand", "describe", "find-definitions", "apropos",
      "xref-callers", "xref-callees", "xref-references",
      "trace", "untrace", "threads",
      "invoke-restart", "abort", "interrupt",
      "capabilities"
    ],
    "notifications": ["welcome", "output", "debug", "debug-return"]
  }
}
```

---

## 6. Debugger Flow

When `eval` encounters an unhandled condition, the server enters the debugger. The sequence of messages is:

```
Client                                  Server
  |                                       |
  |--- eval (id: 1) ------------------->  |
  |<-- notification: output ------------- |  (optional, any output before the error)
  |<-- notification: debug -------------- |  (eval response is NOT sent yet)
  |                                       |
  |   ... client presents restarts ...    |
  |                                       |
  |--- invoke-restart (id: 2) ---------> |  (OR: abort)
  |<-- response: invoke-restart --------- |
  |<-- notification: debug-return ------- |
  |<-- response: eval (id: 1) ----------- |  (now the original eval resolves)
```

**Rules:**

- While a `debug` notification is active, the eval request is suspended. The client must not send another `eval` until the debugger is resolved.
- The client resolves the debugger by sending either `invoke-restart` or `abort`.
- After `invoke-restart` or `abort`, the server sends a `debug-return` notification followed by the `eval` response (which may be a success result or an error, depending on the chosen restart).
- If `abort` is chosen, the eval response will be an error with code `-32000`.
- Debugger nesting (`level` > 1) is not currently supported; `level` is always `1`.

---

## 7. Error Codes

The server uses JSON-RPC 2.0 standard error codes plus application-specific codes in the range `-32000` to `-32099`.

| Code | Name | Description |
|---|---|---|
| `-32700` | Parse error | The incoming message could not be parsed as JSON |
| `-32600` | Invalid request | The JSON object is not a valid JSON-RPC request |
| `-32601` | Method not found | The requested method does not exist |
| `-32602` | Invalid params | The params are invalid for the requested method |
| `-32000` | Lisp condition | An unhandled Lisp condition occurred (general eval error, read error, symbol not found, etc.) |
| `-32001` | Package not found | The specified package does not exist |
| `-32002` | Interrupted | The eval was interrupted by an `interrupt` request |

The `message` field of the error object always contains a human-readable description.

---

## 8. Symbol Representation

Symbols are passed as plain strings in all method parameters and result fields. The string format follows Common Lisp `prin1-to-string` conventions:

| Format | Meaning |
|---|---|
| `"foo"` | Symbol in the current package (unqualified) |
| `"cl-user:foo"` | External symbol `FOO` in package `CL-USER` |
| `"cl-user::bar"` | Internal symbol `BAR` in package `CL-USER` |
| `":keyword"` | Keyword symbol |

Symbol names in results (e.g., `describe.name`, `apropos.symbols[].name`) are returned in their canonical uppercased form unless the symbol was created with vertical-bar escaping. Package names in results use the shortest available name (nickname preferred over full name).

When passing symbols as method parameters (e.g., `symbol` in `find-definitions`), the client may use any case; the server applies `string-upcase` before lookup. Package names in `package` parameters are also case-folded to uppercase.

---

## 9. Kind Values

The `kind` field appears in `completions` candidates, `describe` results, and `apropos` results. The possible values are:

| Value | Meaning |
|---|---|
| `"function"` | Ordinary function (`defun`) |
| `"macro"` | Macro (`defmacro`) |
| `"generic-function"` | Generic function (`defgeneric`) |
| `"variable"` | Special variable (`defvar`, `defparameter`) or lexical variable |
| `"class"` | Class (`defclass`) or structure (`defstruct`) |
| `"special-form"` | Built-in special operator (e.g., `if`, `let`, `quote`) |
| `"keyword"` | Keyword symbol (in the `KEYWORD` package) |
| `"unknown"` | Kind could not be determined |
