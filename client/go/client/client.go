// Package client implements a JSON-RPC 2.0 client over WebSocket for the
// CL-RPC server. It provides:
//
//   - A low-level Client for sending requests and receiving responses/notifications.
//   - Typed wrappers for every CL-RPC method (Eval, Completions, Describe, etc.).
//   - A NotificationHandler interface so callers can react to server-pushed events
//     (output, debug, debug-return).
//
// Concurrency model: a single background goroutine (receiveLoop) reads all
// incoming frames. Responses are dispatched to per-request channels stored in
// the pending map. Notifications are delivered synchronously on the receive
// goroutine, so handler methods must not block.
package client

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"

	"github.com/gorilla/websocket"
)

// Request is a JSON-RPC 2.0 request object.
type Request struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int         `json:"id,omitempty"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params"`
}

// Response is a JSON-RPC 2.0 response or notification object.
type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int             `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
	Method  string          `json:"method,omitempty"` // set for notifications
	Params  json.RawMessage `json:"params,omitempty"` // set for notifications
}

// RPCError is a JSON-RPC 2.0 error object.
type RPCError struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

func (e *RPCError) Error() string {
	return fmt.Sprintf("RPC error %d: %s", e.Code, e.Message)
}

// EvalResult is the result of an eval call.
type EvalResult struct {
	Values  []string `json:"values"`
	Package string   `json:"package"`
}

// CompletionCandidate is a single completion candidate.
type CompletionCandidate struct {
	Label string `json:"label"`
	Kind  string `json:"kind"`
}

// CompletionResult is the result of a completions call.
type CompletionResult struct {
	Candidates []CompletionCandidate `json:"candidates"`
}

// DebugParams is the params of a debug notification.
type DebugParams struct {
	Level     int            `json:"level"`
	Condition string         `json:"condition"`
	Restarts  []DebugRestart `json:"restarts"`
	Frames    []interface{}  `json:"frames"`
}

// DebugRestart describes one available restart in the debugger.
type DebugRestart struct {
	Index       int    `json:"index"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

// OutputParams is the params of an output notification.
type OutputParams struct {
	Text   string `json:"text"`
	Target string `json:"target"`
}

// WelcomeParams is the params of the welcome notification sent on connect.
type WelcomeParams struct {
	ProtocolVersion       string `json:"protocol-version"`
	Implementation        string `json:"implementation"`
	ImplementationVersion string `json:"implementation-version"`
}

// NotificationHandler receives server-pushed notifications.
// Methods are called synchronously on the receive goroutine; they must not block.
type NotificationHandler interface {
	HandleOutput(params OutputParams)
	HandleDebug(params DebugParams)
	HandleDebugReturn()
}

// Client is a WebSocket + JSON-RPC client for the CL-RPC server.
type Client struct {
	conn          *websocket.Conn
	Addr          string
	nextID        int64
	pending       sync.Map // int -> chan Response
	handler       NotificationHandler
	mu            sync.Mutex
	done          chan struct{}
	welcomeParams *WelcomeParams
	welcomeMu     sync.Mutex
}

// New dials addr and starts the receive loop. The caller must call Close when done.
func New(addr string) (*Client, error) {
	conn, _, err := websocket.DefaultDialer.Dial(addr, nil)
	if err != nil {
		return nil, fmt.Errorf("websocket dial failed: %w", err)
	}

	c := &Client{
		conn: conn,
		Addr: addr,
		done: make(chan struct{}),
	}

	go c.receiveLoop()
	return c, nil
}

// SetHandler registers h to receive server notifications.
func (c *Client) SetHandler(h NotificationHandler) {
	c.handler = h
}

// Close shuts down the connection.
func (c *Client) Close() {
	close(c.done)
	c.conn.Close()
}

// Call invokes a JSON-RPC method and waits for the response.
func (c *Client) Call(method string, params interface{}) (Response, error) {
	return c.CallContext(context.Background(), method, params)
}

// CallContextWithID invokes a JSON-RPC method and returns the request ID along
// with the response. When ctx is cancelled before a response arrives the pending
// channel is left in place; call TakeResponseChan(id) to retrieve it later.
func (c *Client) CallContextWithID(ctx context.Context, method string, params interface{}) (int, Response, error) {
	id := int(atomic.AddInt64(&c.nextID, 1))

	req := Request{
		JSONRPC: "2.0",
		ID:      id,
		Method:  method,
		Params:  params,
	}

	ch := make(chan Response, 1)
	c.pending.Store(id, ch)

	c.mu.Lock()
	err := c.conn.WriteJSON(req)
	c.mu.Unlock()
	if err != nil {
		c.pending.Delete(id)
		return id, Response{}, fmt.Errorf("write error: %w", err)
	}

	select {
	case resp := <-ch:
		c.pending.Delete(id)
		return id, resp, nil
	case <-ctx.Done():
		// Leave the pending entry so the caller can retrieve it with TakeResponseChan.
		return id, Response{}, ctx.Err()
	}
}

// CallContext invokes a JSON-RPC method with context and returns the response.
func (c *Client) CallContext(ctx context.Context, method string, params interface{}) (Response, error) {
	_, resp, err := c.CallContextWithID(ctx, method, params)
	return resp, err
}

// GetWelcome returns the welcome params sent by the server on connect, or nil
// if the notification has not been received yet.
func (c *Client) GetWelcome() *WelcomeParams {
	c.welcomeMu.Lock()
	defer c.welcomeMu.Unlock()
	return c.welcomeParams
}

// TakeResponseChan removes and returns the pending response channel for id.
// Used to retrieve an eval response after the context was cancelled by the debugger.
func (c *Client) TakeResponseChan(id int) chan Response {
	val, ok := c.pending.LoadAndDelete(id)
	if !ok {
		return nil
	}
	return val.(chan Response)
}

// receiveLoop reads WebSocket frames and dispatches them to pending channels or
// the notification handler. Runs in a dedicated goroutine.
func (c *Client) receiveLoop() {
	for {
		select {
		case <-c.done:
			return
		default:
		}

		_, data, err := c.conn.ReadMessage()
		if err != nil {
			select {
			case <-c.done:
				return
			default:
				// Connection lost: close all pending channels so callers unblock.
				c.pending.Range(func(key, value interface{}) bool {
					close(value.(chan Response))
					return true
				})
				return
			}
		}

		var resp Response
		if err := json.Unmarshal(data, &resp); err != nil {
			continue
		}

		// Notifications have a method but no id.
		if resp.Method != "" && resp.ID == 0 {
			c.handleNotification(resp)
			continue
		}

		// Route response to the waiting caller.
		if val, ok := c.pending.Load(resp.ID); ok {
			val.(chan Response) <- resp
		}
	}
}

// handleNotification dispatches a server notification.
func (c *Client) handleNotification(resp Response) {
	switch resp.Method {
	case "welcome":
		var params WelcomeParams
		if err := json.Unmarshal(resp.Params, &params); err == nil {
			c.welcomeMu.Lock()
			c.welcomeParams = &params
			c.welcomeMu.Unlock()
		}
	case "output":
		if c.handler != nil {
			var params OutputParams
			if err := json.Unmarshal(resp.Params, &params); err == nil {
				c.handler.HandleOutput(params)
			}
		}
	case "debug":
		if c.handler != nil {
			var params DebugParams
			if err := json.Unmarshal(resp.Params, &params); err == nil {
				c.handler.HandleDebug(params)
			}
		}
	case "debug-return":
		if c.handler != nil {
			c.handler.HandleDebugReturn()
		}
	}
}

// Eval evaluates code in pkg and returns the result values and new package name.
func (c *Client) Eval(code, pkg string) (*EvalResult, error) {
	resp, err := c.Call("eval", map[string]string{"code": code, "package": pkg})
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, resp.Error
	}
	var result EvalResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return nil, fmt.Errorf("failed to parse eval result: %w", err)
	}
	return &result, nil
}

// Completions returns symbol completion candidates for prefix in pkg.
// When internal is true, unexported symbols are included. limit 0 means unlimited.
func (c *Client) Completions(prefix, pkg string, internal bool, limit int) (*CompletionResult, error) {
	params := map[string]interface{}{
		"prefix":  prefix,
		"package": pkg,
	}
	if internal {
		params["internal"] = true
	}
	if limit > 0 {
		params["limit"] = limit
	}

	resp, err := c.Call("completions", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, resp.Error
	}
	var result CompletionResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return nil, fmt.Errorf("failed to parse completions result: %w", err)
	}
	return &result, nil
}

// MacroexpandResult is the result of a macroexpand call.
type MacroexpandResult struct {
	Expansion string `json:"expansion"`
}

// Macroexpand expands a macro form (one level by default).
func (c *Client) Macroexpand(code, pkg string) (*MacroexpandResult, error) {
	resp, err := c.Call("macroexpand", map[string]string{"code": code, "package": pkg})
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, resp.Error
	}
	var result MacroexpandResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return nil, fmt.Errorf("failed to parse macroexpand result: %w", err)
	}
	return &result, nil
}

// DescribeResult is the result of a describe call.
type DescribeResult struct {
	Package   string `json:"package"`
	Name      string `json:"name"`
	Type      string `json:"type"`
	Args      string `json:"args,omitempty"`
	Docstring string `json:"docstring,omitempty"`
}

// Describe returns metadata for symbol in pkg.
func (c *Client) Describe(symbol, pkg string) (*DescribeResult, error) {
	resp, err := c.Call("describe", map[string]string{"symbol": symbol, "package": pkg})
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, resp.Error
	}
	var result DescribeResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return nil, fmt.Errorf("failed to parse describe result: %w", err)
	}
	return &result, nil
}

// Definition is one entry in a find-definitions result.
type Definition struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	File     string `json:"file"`
	Position int    `json:"position"`
}

// FindDefinitionsResult is the result of a find-definitions call.
type FindDefinitionsResult struct {
	Definitions []Definition `json:"definitions"`
}

// FindDefinitions returns the source locations where symbol is defined.
func (c *Client) FindDefinitions(symbol, pkg string) (*FindDefinitionsResult, error) {
	resp, err := c.Call("find-definitions", map[string]string{"symbol": symbol, "package": pkg})
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, resp.Error
	}
	var result FindDefinitionsResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return nil, fmt.Errorf("failed to parse find-definitions result: %w", err)
	}
	return &result, nil
}

// InvokeRestart selects restart index in the active debugger session.
// value is an optional S-expression string for restarts like USE-VALUE.
func (c *Client) InvokeRestart(level, index int, value string) error {
	params := map[string]interface{}{"level": level, "index": index}
	if value != "" {
		params["value"] = value
	}
	resp, err := c.Call("invoke-restart", params)
	if err != nil {
		return err
	}
	if resp.Error != nil {
		return resp.Error
	}
	return nil
}

// Abort aborts from the active debugger session.
func (c *Client) Abort(level int) error {
	resp, err := c.Call("abort", map[string]int{"level": level})
	if err != nil {
		return err
	}
	if resp.Error != nil {
		return resp.Error
	}
	return nil
}

// Interrupt signals the running eval thread to stop. The id parameter is
// reserved for future use and currently ignored by the server.
func (c *Client) Interrupt(evalID int) error {
	resp, err := c.Call("interrupt", map[string]int{"id": evalID})
	if err != nil {
		return err
	}
	if resp.Error != nil {
		return resp.Error
	}
	return nil
}

// SetPackage changes the current package and returns the canonical package name.
func (c *Client) SetPackage(name string) (*EvalResult, error) {
	resp, err := c.Call("set-package", map[string]string{"name": name})
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, resp.Error
	}
	var result EvalResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return nil, fmt.Errorf("failed to parse set-package result: %w", err)
	}
	return &result, nil
}
