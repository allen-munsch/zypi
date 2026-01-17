// zypi-agent - Guest agent running inside Firecracker VMs
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
	"syscall"
	"time"

	"github.com/mdlayher/vsock"
)

const (
	VsockPort    = 52
	MaxFileSize  = 100 * 1024 * 1024 // 100MB
	ReadTimeout  = 30 * time.Second
	WriteTimeout = 30 * time.Second
	AuthToken    = "" // Set via environment variable ZYPI_TOKEN
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
	startTime time.Time
	mu        sync.Mutex
	processes map[string]*exec.Cmd
	token     string
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

	// Try vsock first, fallback to TCP for development
	var listener net.Listener
	var err error
	
	// Only use vsock if token is set (security requirement)
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
			fmt.Println("WARNING: zypi-agent listening on TCP :9999 without authentication")
		} else {
			fmt.Println("zypi-agent listening on TCP :9999 (token auth enabled)")
		}
	}

	defer listener.Close()
	
	for {
		conn, err := listener.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Accept error: %v\n", err)
			continue
		}
		go agent.handleConnection(conn)
	}
}

func (a *Agent) handleConnection(conn net.Conn) {
	defer conn.Close()
	
	// Set timeouts
	conn.SetReadDeadline(time.Now().Add(ReadTimeout))
	conn.SetWriteDeadline(time.Now().Add(WriteTimeout))

	reader := bufio.NewReader(conn)
	encoder := json.NewEncoder(conn)

	for {
		// Reset timeout for each request
		conn.SetReadDeadline(time.Now().Add(ReadTimeout))
		
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err != io.EOF {
				fmt.Fprintf(os.Stderr, "Read error from %s: %v\n", conn.RemoteAddr(), err)
			}
			return
		}

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

		resp := a.handleRequest(&req)
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

	// Basic command validation (allowlist approach)
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

	// Validate path for security
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

	// Log the file write operation
	fmt.Printf("[AUDIT] File written: %s (%d bytes)\n", params.Path, len(content))
	
	return Response{ID: req.ID, Result: map[string]interface{}{"written": len(content)}}
}

func (a *Agent) handleFileRead(req *Request) Response {
	var params FileReadParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32602, Message: err.Error()}}
	}

	// Validate path for security
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

	// Don't allow reading sensitive files
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
	// Log shutdown request
	fmt.Printf("[AUDIT] Shutdown requested by client\n")
	
	go func() {
		time.Sleep(100 * time.Millisecond)
		syscall.Sync()
		syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	}()
	return Response{ID: req.ID, Result: map[string]string{"status": "shutting_down"}}
}

// Security helper functions
func isSafeCommand(cmd string) bool {
	// Very basic allowlist - expand based on your needs
	safeCommands := []string{
		"/bin/", "/usr/bin/", "/usr/local/bin/",
		"ls", "cat", "echo", "grep", "find", "ps", "top",
		"systemctl", "journalctl", "docker", "podman",
	}
	
	for _, safe := range safeCommands {
		if strings.Contains(cmd, safe) {
			return true
		}
	}
	return false
}

func isSafePath(path string) bool {
	// Disallow absolute paths to sensitive locations
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
	
	// Allow paths in /tmp, /var/log, /var/tmp, and current working directories
	allowedPrefixes := []string{
		"/tmp/", "/var/log/", "/var/tmp/", "/home/",
	}
	
	for _, prefix := range allowedPrefixes {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}
	
	// Allow relative paths in current directory
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