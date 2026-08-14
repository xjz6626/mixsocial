package sidecar

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const BinaryName = "xiaohongshu-mcp"

type Config struct {
	Endpoint    string
	Binary      string
	Token       string
	SessionPath string
	LogPath     string
	HTTPClient  *http.Client
}

// Manager owns a sidecar process only when no compatible service is already
// listening. This lets mixsocial remain one command while retaining the option
// to point it at an externally managed service.
type Manager struct {
	endpoint    string
	binary      string
	token       string
	sessionPath string
	logPath     string
	listen      string
	local       bool
	client      *http.Client

	mu      sync.Mutex
	command *exec.Cmd
	done    chan error
	owned   bool
	logFile *os.File
}

func New(config Config) (*Manager, error) {
	endpoint := strings.TrimRight(strings.TrimSpace(config.Endpoint), "/")
	if endpoint == "" {
		endpoint = "http://127.0.0.1:18060"
	}
	listen, local, err := resolveListen(endpoint)
	if err != nil {
		return nil, err
	}
	client := config.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 2 * time.Second}
	}
	return &Manager{
		endpoint: endpoint, binary: strings.TrimSpace(config.Binary), token: config.Token,
		sessionPath: config.SessionPath, logPath: config.LogPath,
		listen: listen, local: local, client: client,
	}, nil
}

func (m *Manager) Endpoint() string { return m.endpoint }

func (m *Manager) Owned() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.owned
}

func (m *Manager) LogPath() string { return m.logPath }

func (m *Manager) Ensure(ctx context.Context) error {
	if m.healthy(ctx) {
		return m.protectSession()
	}
	if !m.local {
		return fmt.Errorf("小红书服务 %s 不可用；远程地址不会被自动启动", m.endpoint)
	}

	m.mu.Lock()
	if m.command == nil {
		if err := m.startLocked(); err != nil {
			m.mu.Unlock()
			return err
		}
	}
	done := m.done
	m.mu.Unlock()

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			_ = m.Close()
			return fmt.Errorf("等待小红书 sidecar 启动: %w", ctx.Err())
		case err := <-done:
			m.mu.Lock()
			m.command = nil
			m.done = nil
			m.owned = false
			m.closeLogLocked()
			m.mu.Unlock()
			if err == nil {
				err = errors.New("进程提前退出")
			}
			return fmt.Errorf("小红书 sidecar 启动失败: %w；日志: %s", err, m.logPath)
		case <-ticker.C:
			if m.healthy(ctx) {
				return m.protectSession()
			}
		}
	}
}

func (m *Manager) startLocked() error {
	binary, err := resolveBinary(m.binary)
	if err != nil {
		return err
	}
	if m.sessionPath == "" || m.logPath == "" {
		return errors.New("sidecar session and log paths must be configured")
	}
	if err := os.MkdirAll(filepath.Dir(m.sessionPath), 0o700); err != nil {
		return fmt.Errorf("创建小红书会话目录: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(m.logPath), 0o700); err != nil {
		return fmt.Errorf("创建 sidecar 日志目录: %w", err)
	}
	if err := os.Chmod(filepath.Dir(m.sessionPath), 0o700); err != nil {
		return fmt.Errorf("保护小红书会话目录: %w", err)
	}
	logFile, err := os.OpenFile(m.logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("打开 sidecar 日志: %w", err)
	}

	command := exec.Command(binary, "-headless=true", "-port="+m.listen)
	configureProcess(command)
	command.Stdout = logFile
	command.Stderr = logFile
	command.Env = replaceEnv(os.Environ(), map[string]string{
		"COOKIES_PATH": m.sessionPath,
		"AUTH_TOKEN":   m.token,
	})
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		return fmt.Errorf("启动 %s: %w", binary, err)
	}

	m.command = command
	m.done = make(chan error, 1)
	m.owned = true
	m.logFile = logFile
	go func(done chan<- error) {
		done <- command.Wait()
	}(m.done)
	return nil
}

func (m *Manager) Close() error {
	m.mu.Lock()
	if !m.owned || m.command == nil {
		m.mu.Unlock()
		return nil
	}
	command, done := m.command, m.done
	m.mu.Unlock()

	_ = stopProcess(command, false)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = stopProcess(command, true)
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
	}

	m.mu.Lock()
	m.command = nil
	m.done = nil
	m.owned = false
	m.closeLogLocked()
	m.mu.Unlock()
	return m.protectSession()
}

func (m *Manager) protectSession() error {
	if m.sessionPath == "" {
		return nil
	}
	if err := os.Chmod(m.sessionPath, 0o600); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("保护小红书会话文件: %w", err)
	}
	return nil
}

func (m *Manager) closeLogLocked() {
	if m.logFile != nil {
		_ = m.logFile.Close()
		m.logFile = nil
	}
}

func (m *Manager) healthy(ctx context.Context) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.endpoint+"/health", nil)
	if err != nil {
		return false
	}
	response, err := m.client.Do(req)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return false
	}
	var health struct {
		Success bool `json:"success"`
		Data    struct {
			Service string `json:"service"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&health); err != nil {
		return false
	}
	return health.Success && health.Data.Service == BinaryName
}

func resolveListen(endpoint string) (listen string, local bool, err error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" {
		return "", false, fmt.Errorf("无效的小红书 endpoint %q", endpoint)
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return "", false, fmt.Errorf("小红书 endpoint 不能带路径: %q", endpoint)
	}
	host := parsed.Hostname()
	ip := net.ParseIP(host)
	local = strings.EqualFold(host, "localhost") || (ip != nil && ip.IsLoopback())
	port := parsed.Port()
	if port == "" {
		if parsed.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	if !local {
		return net.JoinHostPort(host, port), false, nil
	}
	// Bind managed services to IPv4 loopback only; never expose the browser API
	// on all interfaces merely because the client used "localhost".
	return net.JoinHostPort("127.0.0.1", port), true, nil
}

func resolveBinary(explicit string) (string, error) {
	if explicit != "" {
		path, err := exec.LookPath(explicit)
		if err != nil {
			return "", fmt.Errorf("找不到小红书 sidecar %q: %w", explicit, err)
		}
		return path, nil
	}
	if executable, err := os.Executable(); err == nil {
		sibling := filepath.Join(filepath.Dir(executable), BinaryName)
		if info, statErr := os.Stat(sibling); statErr == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return sibling, nil
		}
	}
	if path, err := exec.LookPath(BinaryName); err == nil {
		return path, nil
	}
	return "", fmt.Errorf("找不到 %s；请重新运行 mixsocial 的 install.sh，或使用 --xhs-sidecar 指定路径", BinaryName)
}

func replaceEnv(current []string, replacements map[string]string) []string {
	result := make([]string, 0, len(current)+len(replacements))
	for _, entry := range current {
		name, _, _ := strings.Cut(entry, "=")
		if _, replaced := replacements[name]; !replaced {
			result = append(result, entry)
		}
	}
	for name, value := range replacements {
		result = append(result, name+"="+value)
	}
	return result
}
