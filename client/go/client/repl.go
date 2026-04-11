package client

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"

	"github.com/peterh/liner"
)

// REPL is an interactive Common Lisp RPC session.
type REPL struct {
	client      *Client
	pkg         string
	host        string
	rl          *liner.State
	debugLevel  int
	debugParams *DebugParams
	debugMu     sync.Mutex
	inDebug     bool
	// evalCancel cancels the context passed to the active eval CallContextWithID.
	// Non-nil only while an eval is in flight. Protected by debugMu.
	evalCancel context.CancelFunc
	quit       bool
}

const historyFile = "/tmp/cl-rpc-client-history"

// NewREPL creates a new REPL connected to c.
func NewREPL(c *Client) (*REPL, error) {
	host := c.Addr
	if u, err := url.Parse(c.Addr); err == nil {
		host = u.Host
	}
	r := &REPL{
		client: c,
		pkg:    "cl-user",
		host:   host,
	}

	c.SetHandler(r)

	if result, err := c.SetPackage("cl-user"); err == nil && result.Package != "" {
		r.pkg = strings.ToLower(result.Package)
	}

	rl := liner.NewLiner()
	rl.SetCtrlCAborts(true)

	rl.SetCompleter(func(line string) []string {
		return r.completionFunc(line)
	})

	if f, err := os.Open(historyFile); err == nil {
		rl.ReadHistory(f)
		f.Close()
	}

	r.rl = rl

	// Print server info from the welcome notification (stored in client).
	if w := c.GetWelcome(); w != nil {
		fmt.Printf("Server: %s %s (protocol %s)\n",
			w.Implementation, w.ImplementationVersion, w.ProtocolVersion)
	}

	return r, nil
}

// prompt returns the prompt string.
func (r *REPL) prompt() string {
	return strings.ToLower(r.pkg) + "@" + r.host + "> "
}

// lastToken returns the last token on a line (the completion target).
func lastToken(line string) string {
	delimiters := " \t\n()\",'`;"
	last := strings.LastIndexAny(line, delimiters)
	if last == -1 {
		return line
	}
	return line[last+1:]
}

// splitPrefix splits "pkg:sym" / "pkg::sym" into components.
func splitPrefix(token, defaultPkg string) (string, string, bool, string) {
	colon := strings.Index(token, ":")
	if colon == -1 {
		return token, defaultPkg, false, ""
	}
	if colon+1 < len(token) && token[colon+1] == ':' {
		return token[colon+2:], token[:colon], true, token[:colon+2]
	}
	return token[colon+1:], token[:colon], false, token[:colon+1]
}

// completionFunc returns TAB completion candidates.
func (r *REPL) completionFunc(line string) []string {
	token := lastToken(line)
	if token == "" {
		return nil
	}

	prefix, targetPkg, internal, head := splitPrefix(token, r.pkg)
	useInternal := internal
	if targetPkg == r.pkg {
		useInternal = true
	}

	result, err := r.client.Completions(prefix, targetPkg, useInternal, 100)
	if err != nil {
		return nil
	}

	before := line[:len(line)-len(token)]
	candidates := make([]string, 0, len(result.Candidates))
	for _, c := range result.Candidates {
		candidates = append(candidates, before+head+c.Label)
	}
	return candidates
}

// parenDepth returns the net paren depth of s (considering string literals).
func parenDepth(s string) int {
	depth := 0
	inString := false
	escaped := false
	for _, ch := range s {
		if escaped {
			escaped = false
			continue
		}
		if ch == '\\' && inString {
			escaped = true
			continue
		}
		if ch == '"' {
			inString = !inString
			continue
		}
		if inString {
			continue
		}
		switch ch {
		case '(':
			depth++
		case ')':
			depth--
		}
	}
	return depth
}

// readContinuation reads additional lines until open parens are all closed.
func (r *REPL) readContinuation(initialDepth int) (string, error) {
	var lines []string
	depth := initialDepth

	for depth > 0 {
		line, err := r.rl.Prompt("  ")
		if err != nil {
			return "", err
		}
		lines = append(lines, line)
		depth += parenDepth(line)
	}

	return strings.Join(lines, "\n"), nil
}

// Run runs the REPL main loop.
func (r *REPL) Run() error {
	defer func() {
		if f, err := os.Create(historyFile); err == nil {
			r.rl.WriteHistory(f)
			f.Close()
		}
		r.rl.Close()
	}()

	// Ctrl+C while an eval is in flight → send interrupt.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)
	defer signal.Stop(sigCh)
	go func() {
		for range sigCh {
			r.debugMu.Lock()
			inEval := r.evalCancel != nil
			r.debugMu.Unlock()
			if inEval {
				fmt.Fprintln(os.Stdout, "\nInterrupting...")
				if err := r.client.Interrupt(0); err != nil {
					fmt.Fprintf(os.Stdout, "Interrupt error: %v\n", err)
				}
			}
		}
	}()

	fmt.Printf("Connected to Common Lisp RPC server (package: %s)\n", r.pkg)
	fmt.Println("Type :q or Ctrl-D to quit. :help for commands.")

	for {
		if r.quit {
			fmt.Println("Goodbye.")
			return nil
		}

		var prompt string
		if r.inDebug {
			prompt = "debug> "
		} else {
			prompt = r.prompt()
		}

		line, err := r.rl.Prompt(prompt)
		if err == liner.ErrPromptAborted {
			r.debugMu.Lock()
			inEval := r.evalCancel != nil
			r.debugMu.Unlock()
			if inEval {
				fmt.Println("\nInterrupting...")
				if ierr := r.client.Interrupt(0); ierr != nil {
					fmt.Printf("Interrupt error: %v\n", ierr)
				}
			} else {
				fmt.Println("Interrupted. Use :q to quit.")
			}
			continue
		} else if err == io.EOF {
			fmt.Println("\nGoodbye.")
			return nil
		} else if err != nil {
			return err
		}

		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		r.rl.AppendHistory(line)

		if strings.HasPrefix(line, ":") {
			if r.inDebug {
				r.handleDebugCommand(line)
			} else {
				r.handleCommand(line)
			}
			continue
		}

		if r.inDebug {
			r.handleDebugEval(line)
		} else {
			r.handleEval(line)
		}
	}
}

// handleCommand handles colon commands in normal mode.
func (r *REPL) handleCommand(line string) {
	switch {
	case line == ":q" || line == ":quit" || line == ":exit":
		r.quit = true

	case strings.HasPrefix(line, ":pkg ") || strings.HasPrefix(line, ":package "):
		parts := strings.Fields(line)
		if len(parts) < 2 {
			fmt.Println("Usage: :pkg <package-name>")
			return
		}
		r.handleSetPackage(parts[1])

	case strings.HasPrefix(line, ":macroexpand ") || strings.HasPrefix(line, ":m "):
		code := strings.TrimPrefix(strings.TrimPrefix(line, ":macroexpand "), ":m ")
		result, err := r.client.Macroexpand(code, r.pkg)
		if err != nil {
			fmt.Printf("Error: %v\n", err)
			return
		}
		fmt.Println(result.Expansion)

	case strings.HasPrefix(line, ":describe ") || strings.HasPrefix(line, ":d "):
		symbol := strings.TrimPrefix(strings.TrimPrefix(line, ":describe "), ":d ")
		result, err := r.client.Describe(strings.TrimSpace(symbol), r.pkg)
		if err != nil {
			fmt.Printf("Error: %v\n", err)
			return
		}
		fmt.Printf("%s:%s  [%s]\n", result.Package, result.Name, result.Type)
		if result.Args != "" {
			fmt.Printf("Args: %s\n", result.Args)
		}
		if result.Docstring != "" {
			fmt.Println(result.Docstring)
		}

	case line == ":help" || line == ":h":
		fmt.Println("Commands:")
		fmt.Println("  :pkg <name>       - switch package")
		fmt.Println("  :m <form>         - macroexpand form")
		fmt.Println("  :d <symbol>       - describe symbol")
		fmt.Println("  :q                - quit")
		fmt.Println("  :help             - show this help")
		fmt.Println("  Ctrl-C            - interrupt running eval")
		fmt.Println("  Tab               - autocomplete")

	default:
		fmt.Printf("Unknown command: %s (try :help)\n", line)
	}
}

// handleSetPackage sends a set-package request.
func (r *REPL) handleSetPackage(name string) {
	result, err := r.client.SetPackage(name)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	if result.Package != "" {
		r.pkg = strings.ToLower(result.Package)
		fmt.Printf("Package: %s\n", r.pkg)
	}
}

// handleEval sends an eval request and displays the result.
// When the debugger fires, it returns immediately so the REPL loop can process
// debug commands. A background goroutine waits for the eventual eval response
// (which arrives after debug-return once a restart is selected).
func (r *REPL) handleEval(code string) {
	if d := parenDepth(code); d > 0 {
		rest, err := r.readContinuation(d)
		if err != nil {
			if err != io.EOF && err != liner.ErrPromptAborted {
				fmt.Printf("Read error: %v\n", err)
			}
			return
		}
		if rest != "" {
			code = code + "\n" + rest
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	r.debugMu.Lock()
	r.evalCancel = cancel
	r.debugMu.Unlock()
	defer func() {
		r.debugMu.Lock()
		r.evalCancel = nil
		r.debugMu.Unlock()
		cancel()
	}()

	evalID, resp, err := r.client.CallContextWithID(ctx, "eval",
		map[string]string{"code": code, "package": r.pkg})

	if err == context.Canceled {
		// The debugger was entered. The server will send debug-return followed by
		// the eval response. Start a goroutine to receive and print it so the REPL
		// loop is unblocked immediately and can process debug commands.
		ch := r.client.TakeResponseChan(evalID)
		if ch != nil {
			go func() {
				if finalResp, ok := <-ch; ok {
					r.printEvalResponse(finalResp)
				}
			}()
		}
		return
	}

	if err != nil {
		fmt.Fprintf(os.Stdout, "Error: %v\n", err)
		return
	}
	r.printEvalResponse(resp)
}

// printEvalResponse displays an eval response.
func (r *REPL) printEvalResponse(resp Response) {
	if resp.Error != nil {
		fmt.Fprintf(os.Stdout, "Error: %v\n", resp.Error)
		return
	}
	var result EvalResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		fmt.Fprintf(os.Stdout, "Error parsing result: %v\n", err)
		return
	}
	for _, v := range result.Values {
		fmt.Fprintln(os.Stdout, v)
	}
	if result.Package != "" && strings.ToUpper(result.Package) != strings.ToUpper(r.pkg) {
		r.pkg = strings.ToLower(result.Package)
	}
}

// handleDebugEval rejects eval calls while the debugger is active.
// The server enforces the same restriction; this avoids the round-trip.
func (r *REPL) handleDebugEval(_ string) {
	fmt.Fprintln(os.Stdout, "; Eval is not available while the debugger is active.")
	fmt.Fprintln(os.Stdout, "; Use :r <N> to invoke a restart, or :a to abort.")
}

// handleDebugCommand processes colon commands in debugger mode.
func (r *REPL) handleDebugCommand(line string) {
	r.debugMu.Lock()
	params := r.debugParams
	level := r.debugLevel
	r.debugMu.Unlock()

	if params == nil {
		return
	}

	switch {
	case line == ":a" || line == ":abort":
		fmt.Printf("Aborting level %d...\n", level)
		if err := r.client.Abort(level); err != nil {
			fmt.Printf("Abort error: %v\n", err)
		}

	case strings.HasPrefix(line, ":r "):
		var idx int
		if _, err := fmt.Sscanf(line, ":r %d", &idx); err != nil {
			fmt.Println("Usage: :r <N>")
			return
		}
		if idx < 0 || idx >= len(params.Restarts) {
			fmt.Printf("Invalid restart index %d (valid: 0-%d)\n", idx, len(params.Restarts)-1)
			return
		}
		restart := params.Restarts[idx]
		fmt.Printf("Invoking restart %d: %s\n", idx, restart.Name)
		var value string
		switch strings.ToUpper(restart.Name) {
		case "USE-VALUE", "STORE-VALUE":
			v, err := r.rl.Prompt(fmt.Sprintf("Value for %s: ", restart.Name))
			if err == nil {
				value = strings.TrimSpace(v)
			}
		}
		if err := r.client.InvokeRestart(level, idx, value); err != nil {
			fmt.Printf("InvokeRestart error: %v\n", err)
		}

	case line == ":restarts" || line == ":r":
		r.showRestarts(params)

	case line == ":frames" || line == ":bt" || line == ":backtrace":
		r.showFrames(params)

	case line == ":q" || line == ":quit":
		fmt.Println("Use :a to abort the debugger first.")

	case line == ":help" || line == ":h":
		fmt.Println("Debugger commands:")
		fmt.Println("  :r <N>     - invoke restart N")
		fmt.Println("  :r         - list restarts")
		fmt.Println("  :a         - abort")
		fmt.Println("  :bt        - show backtrace frames")

	default:
		fmt.Printf("Unknown debug command: %s (try :help)\n", line)
	}
}

// showRestarts displays the restart list.
func (r *REPL) showRestarts(params *DebugParams) {
	fmt.Fprintf(os.Stdout, "Debugger [level %d]: %s\n", params.Level, params.Condition)
	if len(params.Restarts) == 0 {
		fmt.Fprintln(os.Stdout, "  (no restarts available)")
		return
	}
	for _, restart := range params.Restarts {
		fmt.Fprintf(os.Stdout, "  %d: [%s] %s\n", restart.Index, restart.Name, restart.Description)
	}
}

// showFrames displays backtrace frames.
func (r *REPL) showFrames(params *DebugParams) {
	if len(params.Frames) == 0 {
		fmt.Println("  (no frames available)")
		return
	}
	fmt.Println("Backtrace:")
	for i, f := range params.Frames {
		fmt.Printf("  %d: %v\n", i, f)
	}
}

// HandleOutput handles output notifications (NotificationHandler implementation).
func (r *REPL) HandleOutput(params OutputParams) {
	if params.Target == "stderr" {
		for _, line := range strings.Split(params.Text, "\n") {
			if line != "" {
				fmt.Fprintf(os.Stdout, "; %s\n", line)
			}
		}
	} else {
		fmt.Fprint(os.Stdout, params.Text)
	}
}

// HandleDebug handles debug notifications (NotificationHandler implementation).
func (r *REPL) HandleDebug(params DebugParams) {
	r.debugMu.Lock()
	r.debugLevel = params.Level
	r.debugParams = &params
	r.inDebug = true
	cancel := r.evalCancel
	r.debugMu.Unlock()

	fmt.Fprintln(os.Stdout)
	r.showRestarts(&params)
	fmt.Fprintln(os.Stdout, "Type :help for debugger commands.")

	if cancel != nil {
		cancel()
	}
}

// HandleDebugReturn handles debug-return notifications (NotificationHandler implementation).
// The eval response (success or error) arrives after this notification; the goroutine
// started in handleEval will receive and print it.
func (r *REPL) HandleDebugReturn() {
	r.debugMu.Lock()
	r.inDebug = false
	r.debugParams = nil
	r.debugMu.Unlock()
}
