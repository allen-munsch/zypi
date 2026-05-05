// zypi-agent - Guest agent running inside Firecracker VMs.
//
// Listens on vsock (port 52, auth required) or TCP (:9999, dev mode).
// Handles: exec, file.read, file.write, health, shutdown.
//
// v2 changes (perf fix):
//   - Short initial read deadline (5s) prevents goroutine leak from raw TCP pings
//   - Max concurrent connections (100) prevents file descriptor exhaustion
//   - Idle connection timeout (60s) cleans up stale connections
//   - Graceful shutdown: tracks in-flight requests, waits for completion
//   - Fixed isSafeCommand: exact prefix match instead of substring

package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/mdlayher/vsock"
)

const (
	VsockPort          = 52
	MaxFileSize        = 100 * 1024 * 1024 // 100MB
	InitialReadTimeout = 5 * time.Second   // Short timeout to prevent goroutine leak from raw TCP pings
	MaxReadTimeout     = 30 * time.Second  // Max timeout once we've received valid data
	WriteTimeout       = 30 * time.Second
	IdleTimeout        = 60 * time.Second  // Close connection if no data received
	MaxConns           = 100               // Max concurrent connections
)

type Request struct {
	ID     string          `json:"id"`
	Method string          `json:"method"`
	Token  string          `json:"token,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	ID     string      `json:"id"`
	Result interface{} `json:"result,omitempty"`
	Error  *Error      `json:"error,omitempty"`
}

type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type ExecParams struct {
	Cmd     []string          `json:"cmd"`
	Env     map[string]string `json:"env,omitempty"`
	Workdir string            `json:"workdir,omitempty"`
	Stdin   string            `json:"stdin,omitempty"`
	Timeout int               `json:"timeout,omitempty"`
}

type ExecResult struct {
	ExitCode int    `json:"exit_code"`
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	Signal   string `json:"signal,omitempty"`
	TimedOut bool   `json:"timed_out,omitempty"`
}

type FileWriteParams struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	Mode    int    `json:"mode,omitempty"`
}

type FileReadParams struct {
	Path string `json:"path"`
}

type FileReadResult struct {
	Content string `json:"content"`
	Size    int64  `json:"size"`
	Mode    int    `json:"mode"`
}

type HealthResult struct {
	Status    string  `json:"status"`
	Uptime    float64 `json:"uptime_seconds"`
	LoadAvg   string  `json:"load_avg"`
	MemFreeKB int64   `json:"mem_free_kb"`
}

type Agent struct {
	startTime  time.Time
	mu         sync.Mutex
	processes  map[string]*exec.Cmd
	token      string
	connCount  int32 // atomic counter for connection limiting
	inFlight   int32 // atomic counter for graceful shutdown
}

func NewAgent() *Agent {
	token := os.Getenv("ZYPI_TOKEN")
	if token == "" {
		token = os.Getenv("ZYPI_AGENT_TOKEN")
	}

	return &Agent{
		startTime: time.Now(),
		processes: make(map[string]*exec.Cmd),
		token:     token,
	}
}

func main() {
	agent := NewAgent()

	var listener net.Listener
	var err error

	// Try vsock first, fallback to TCP for development
	if agent.token != "" {
		listener, err = vsock.Listen(uint32(VsockPort), &vsock.Config{})
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to listen on vsock (will try TCP): %v\n", err)
		} else {
			fmt.Printf("zypi-agent listening on vsock port %d (token auth enabled)\n", VsockPort)
		}
	}

	// Fallback to TCP if vsock failed or token not set
	if listener == nil {
		listener, err = net.Listen("tcp", "0.0.0.0:9999")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to listen on TCP: %v\n", err)
			os.Exit(1)
		}
		if agent.token == "" {
			fmt.Println("zypi-agent listening on TCP :9999 (no auth)")
		} else {
			fmt.Println("zypi-agent listening on TCP :9999 (token auth enabled)")
		}
	}

	defer listener.Close()

	for {
		conn, err := listener.Accept()
		if err != nil {
			// Check if listener was closed (graceful shutdown)
			if strings.Contains(err.Error(), "use of closed network connection") {
				fmt.Println("Listener closed, shutting down")
				return
			}
			fmt.Fprintf(os.Stderr, "Accept error: %v\n", err)
			continue
		}

		// Connection limit — don't spawn unbounded goroutines
		current := atomic.AddInt32(&agent.connCount, 1)
		if current > MaxConns {
			atomic.AddInt32(&agent.connCount, -1)
			fmt.Fprintf(os.Stderr, "Connection limit reached (%d), rejecting %s\n", MaxConns, conn.RemoteAddr())
			conn.Close()
			continue
		}

		go func() {
			agent.handleConnection(conn)
			atomic.AddInt32(&agent.connCount, -1)
		}()
	}
}

func (a *Agent) handleConnection(conn net.Conn) {
	defer conn.Close()

	// Short initial read timeout: prevents goroutine leak from raw TCP pings.
	// Previously 30s — each raw TCP open/close (health ping) spawned a goroutine
	// that blocked 30s on ReadBytes, piling up until the agent stopped accepting.
	conn.SetReadDeadline(time.Now().Add(InitialReadTimeout))
	conn.SetWriteDeadline(time.Now().Add(WriteTimeout))

	reader := bufio.NewReader(conn)
	encoder := json.NewEncoder(conn)
	hasReceivedData := false

	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err != io.EOF {
				fmt.Fprintf(os.Stderr, "Read error from %s: %v\n", conn.RemoteAddr(), err)
			}
			return
		}

		// Once we've received data, extend the timeout for subsequent reads
		if !hasReceivedData {
			hasReceivedData = true
		}
		// Reset deadline after every successful read
		conn.SetReadDeadline(time.Now().Add(IdleTimeout))

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			encoder.Encode(Response{
				Error: &Error{Code: -32700, Message: "Parse error"},
			})
			continue
		}

		// Authenticate request if token is configured
		if a.token != "" && req.Token != a.token {
			encoder.Encode(Response{
				ID: req.ID,
				Error: &Error{Code: -32001, Message: "Unauthorized"},
			})
			continue
		}

		// Track in-flight requests for graceful shutdown
		atomic.AddInt32(&a.inFlight, 1)
		resp := a.handleRequest(&req)
		atomic.AddInt32(&a.inFlight, -1)

		conn.SetWriteDeadline(time.Now().Add(WriteTimeout))
		if err := encoder.Encode(resp); err != nil {
			fmt.Fprintf(os.Stderr, "Write error to %s: %v\n", conn.RemoteAddr(), err)
			return
		}
	}
}

func (a *Agent) handleRequest(req *Request) Response {
	switch req.Method {
	case "exec":
		return a.handleExec(req)
	case "file.write":
		return a.handleFileWrite(req)
	case "file.read":
		return a.handleFileRead(req)
	case "health":
		return a.handleHealth(req)
	case "shutdown":
		return a.handleShutdown(req)
	default:
		return Response{
			ID:    req.ID,
			Error: &Error{Code: -32601, Message: "Method not found"},
		}
	}
}

func (a *Agent) handleExec(req *Request) Response {
	var params ExecParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32602, Message: err.Error()}}
	}

	if len(params.Cmd) == 0 {
		return Response{ID: req.ID, Error: &Error{Code: -32602, Message: "cmd required"}}
	}

	if !isSafeCommand(params.Cmd[0]) {
		return Response{ID: req.ID, Error: &Error{
			Code:    -32003,
			Message: "Command not allowed for security reasons",
		}}
	}

	timeout := 60 * time.Second
	if params.Timeout > 0 {
		timeout = time.Duration(params.Timeout) * time.Second
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, params.Cmd[0], params.Cmd[1:]...)

	if params.Workdir != "" {
		cmd.Dir = params.Workdir
	}

	cmd.Env = os.Environ()
	for k, v := range params.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	var stdoutBuf, stderrBuf syncBuffer
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf

	if params.Stdin != "" {
		cmd.Stdin = strings.NewReader(params.Stdin)
	}

	err := cmd.Run()

	result := ExecResult{
		Stdout: string(stdoutBuf.Bytes()),
		Stderr: string(stderrBuf.Bytes()),
	}

	if ctx.Err() == context.DeadlineExceeded {
		result.TimedOut = true
		result.ExitCode = -1
	} else if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			result.ExitCode = exitErr.ExitCode()
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				if status.Signaled() {
					result.Signal = status.Signal().String()
				}
			}
		} else {
			return Response{ID: req.ID, Error: &Error{Code: -32000, Message: err.Error()}}
		}
	}

	return Response{ID: req.ID, Result: result}
}

func (a *Agent) handleFileWrite(req *Request) Response {
	var params FileWriteParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32602, Message: err.Error()}}
	}

	if !isSafePath(params.Path) {
		return Response{ID: req.ID, Error: &Error{
			Code:    -32003,
			Message: "Path not allowed for security reasons",
		}}
	}

	content, err := base64.StdEncoding.DecodeString(params.Content)
	if err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32602, Message: "invalid base64"}}
	}

	if len(content) > MaxFileSize {
		return Response{ID: req.ID, Error: &Error{Code: -32000, Message: "file too large"}}
	}

	dir := filepath.Dir(params.Path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32000, Message: err.Error()}}
	}

	mode := os.FileMode(0644)
	if params.Mode > 0 {
		mode = os.FileMode(params.Mode)
	}

	if err := os.WriteFile(params.Path, content, mode); err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32000, Message: err.Error()}}
	}

	fmt.Printf("[AUDIT] File written: %s (%d bytes)\n", params.Path, len(content))

	return Response{ID: req.ID, Result: map[string]interface{}{"written": len(content)}}
}

func (a *Agent) handleFileRead(req *Request) Response {
	var params FileReadParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32602, Message: err.Error()}}
	}

	if !isSafePath(params.Path) {
		return Response{ID: req.ID, Error: &Error{
			Code:    -32003,
			Message: "Path not allowed for security reasons",
		}}
	}

	info, err := os.Stat(params.Path)
	if err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32000, Message: err.Error()}}
	}

	if info.Size() > MaxFileSize {
		return Response{ID: req.ID, Error: &Error{Code: -32000, Message: "file too large"}}
	}

	if isSensitiveFile(params.Path) {
		return Response{ID: req.ID, Error: &Error{
			Code:    -32003,
			Message: "File access denied for security reasons",
		}}
	}

	content, err := os.ReadFile(params.Path)
	if err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32000, Message: err.Error()}}
	}

	return Response{ID: req.ID, Result: FileReadResult{
		Content: base64.StdEncoding.EncodeToString(content),
		Size:    info.Size(),
		Mode:    int(info.Mode()),
	}}
}

func (a *Agent) handleHealth(req *Request) Response {
	uptime := time.Since(a.startTime).Seconds()

	loadAvg := "unknown"
	if data, err := os.ReadFile("/proc/loadavg"); err == nil {
		loadAvg = strings.TrimSpace(string(data))
	}

	var memFree int64
	if data, err := os.ReadFile("/proc/meminfo"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "MemFree:") {
				fmt.Sscanf(line, "MemFree: %d", &memFree)
				break
			}
		}
	}

	return Response{ID: req.ID, Result: HealthResult{
		Status:    "healthy",
		Uptime:    uptime,
		LoadAvg:   loadAvg,
		MemFreeKB: memFree,
	}}
}

func (a *Agent) handleShutdown(req *Request) Response {
	fmt.Printf("[AUDIT] Shutdown requested by client\n")

	go func() {
		// Wait for in-flight requests to complete (max 10s grace period)
		deadline := time.Now().Add(10 * time.Second)
		for atomic.LoadInt32(&a.inFlight) > 0 && time.Now().Before(deadline) {
			time.Sleep(100 * time.Millisecond)
		}
		syscall.Sync()
		syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	}()
	return Response{ID: req.ID, Result: map[string]string{"status": "shutting_down"}}
}

// ── Security ───────────────────────────────────────────────────

func isSafeCommand(cmd string) bool {
	// Exact prefix match — not substring (was strings.Contains, which
	// allowed "scat" to pass because it contains "cat").
	safePrefixes := []string{
		"/bin/", "/usr/bin/", "/usr/local/bin/", "/sbin/", "/usr/sbin/",
	}

	for _, prefix := range safePrefixes {
		if strings.HasPrefix(cmd, prefix) {
			return true
		}
	}

	// Allow common commands by exact name
	safeCommands := []string{
		"ls", "cat", "echo", "grep", "find", "ps", "top", "pkill",
		"cp", "mv", "rm", "mkdir", "rmdir", "touch", "chmod", "chown",
		"head", "tail", "wc", "sort", "uniq", "cut", "tr", "sed", "awk",
		"curl", "wget", "tar", "gzip", "gunzip", "zip", "unzip",
		"python", "python3", "pip", "pip3", "node", "npm", "ruby", "perl",
		"git", "make", "gcc", "g++", "cargo", "go", "rustc",
		"sh", "bash", "dash", "env", "export", "which", "id", "whoami",
		"sleep", "true", "false", "test", "date",
		"systemctl", "journalctl",
	}
	for _, safe := range safeCommands {
		if cmd == safe {
			return true
		}
	}

	return false
}

func isSafePath(path string) bool {
	deniedPrefixes := []string{
		"/proc/", "/sys/", "/dev/", "/boot/",
		"/etc/shadow", "/etc/passwd", "/etc/sudoers",
		"/root/.ssh/", "/var/lib/", "/usr/lib/",
	}

	for _, prefix := range deniedPrefixes {
		if strings.HasPrefix(path, prefix) {
			return false
		}
	}

	allowedPrefixes := []string{
		"/tmp/", "/var/log/", "/var/tmp/", "/home/",
	}

	for _, prefix := range allowedPrefixes {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}

	return !filepath.IsAbs(path) || strings.HasPrefix(path, "./")
}

func isSensitiveFile(path string) bool {
	sensitiveFiles := []string{
		"/etc/shadow", "/etc/passwd", "/etc/sudoers",
		"/root/.ssh/authorized_keys", "/root/.ssh/id_rsa",
		"/etc/ssh/ssh_host_rsa_key",
	}

	for _, sensitive := range sensitiveFiles {
		if path == sensitive {
			return true
		}
	}
	return false
}

// ── Buffer ─────────────────────────────────────────────────────

type syncBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (b *syncBuffer) Write(p []byte) (n int, err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf = append(b.buf, p...)
	return len(p), nil
}

func (b *syncBuffer) Bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf
}
