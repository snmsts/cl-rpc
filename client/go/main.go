// cl-rpc-client is a terminal REPL for the CL-RPC server.
//
// Usage:
//
//	cl-rpc-client [-host HOST] [-port PORT]
//
// Flags:
//
//	-host  Server hostname (default: localhost)
//	-port  Server port    (default: 7654)
//
// The REPL connects via WebSocket and speaks JSON-RPC 2.0.
// See docs/protocol.md for the protocol specification.
//
// REPL commands (prefix with colon):
//
//	:pkg <name>   switch current package
//	:m <form>     macroexpand-1
//	:d <symbol>   describe symbol
//	:q            quit
//	:help         show command list
//	Tab           symbol completion
//	Ctrl-C        interrupt a running eval
//
// Debugger commands (shown when the server enters the debugger):
//
//	:r <N>        invoke restart N
//	:r            list restarts
//	:a            abort
//	:bt           show backtrace
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/snmsts/cl-rpc/client/go/client"
)

func main() {
	host := flag.String("host", "localhost", "server host")
	port := flag.Int("port", 7654, "server port")
	flag.Parse()

	addr := fmt.Sprintf("ws://%s:%d", *host, *port)

	fmt.Printf("Connecting to %s ...\n", addr)
	c, err := client.New(addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Connection failed: %v\n", err)
		os.Exit(1)
	}
	defer c.Close()

	repl, err := client.NewREPL(c)
	if err != nil {
		fmt.Fprintf(os.Stderr, "REPL init failed: %v\n", err)
		os.Exit(1)
	}

	if err := repl.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "REPL error: %v\n", err)
		os.Exit(1)
	}
}
