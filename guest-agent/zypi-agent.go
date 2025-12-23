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
)

const (
	VsockPort    = 52
	MaxFileSize  = 100 * 1024 * 1024
	ReadTimeout  = 30 * time.Second
	WriteTimeout = 30 * time.Second
)

type Request struct {
	ID     string          `json:"id"`
	Method string          `json:"method"`
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
}

func NewAgent() *Agent {
	return &Agent{
		startTime: time.Now(),
		processes: make(map[string]*exec.Cmd),
	}
}

func main() {
	agent := NewAgent()

	listener, err := listenVsock(VsockPort)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to listen on vsock: %v\n", err)
		listener, err = net.Listen("tcp", "0.0.0.0:9999")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to listen on TCP fallback: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("zypi-agent listening on TCP :9999 (fallback mode)")
	} else {
		fmt.Println("zypi-agent listening on vsock port", VsockPort)
	}

	for {
		conn, err := listener.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Accept error: %v\n", err)
			continue
		}
		go agent.handleConnection(conn)
	}
}

func listenVsock(port int) (net.Listener, error) {
	fd, err := syscall.Socket(syscall.AF_VSOCK, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("socket: %w", err)
	}

	sa := &syscall.SockaddrVM{
		CID:  syscall.VMADDR_CID_ANY,
		Port: uint32(port),
	}
	if err := syscall.Bind(fd, sa); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("bind: %w", err)
	}

	if err := syscall.Listen(fd, 128); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("listen: %w", err)
	}

	file := os.NewFile(uintptr(fd), "vsock")
	return net.FileListener(file)
}

func (a *Agent) handleConnection(conn net.Conn) {
	defer conn.Close()

	reader := bufio.NewReader(conn)
	encoder := json.NewEncoder(conn)

	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err != io.EOF {
				fmt.Fprintf(os.Stderr, "Read error: %v\n", err)
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

		resp := a.handleRequest(&req)
		if err := encoder.Encode(resp); err != nil {
			fmt.Fprintf(os.Stderr, "Write error: %v\n", err)
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

	return Response{ID: req.ID, Result: map[string]interface{}{"written": len(content)}}
}

func (a *Agent) handleFileRead(req *Request) Response {
	var params FileReadParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32602, Message: err.Error()}}
	}

	info, err := os.Stat(params.Path)
	if err != nil {
		return Response{ID: req.ID, Error: &Error{Code: -32000, Message: err.Error()}}
	}

	if info.Size() > MaxFileSize {
		return Response{ID: req.ID, Error: &Error{Code: -32000, Message: "file too large"}}
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
	go func() {
		time.Sleep(100 * time.Millisecond)
		syscall.Sync()
		syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	}()
	return Response{ID: req.ID, Result: map[string]string{"status": "shutting_down"}}
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
