package sidecar

import (
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) { return f(request) }

func TestResolveListen(t *testing.T) {
	tests := []struct {
		endpoint string
		listen   string
		local    bool
	}{
		{"http://127.0.0.1:18060", "127.0.0.1:18060", true},
		{"http://localhost:19000", "127.0.0.1:19000", true},
		{"https://example.com", "example.com:443", false},
	}
	for _, test := range tests {
		listen, local, err := resolveListen(test.endpoint)
		if err != nil {
			t.Fatalf("%s: %v", test.endpoint, err)
		}
		if listen != test.listen || local != test.local {
			t.Fatalf("%s = (%q, %v), want (%q, %v)", test.endpoint, listen, local, test.listen, test.local)
		}
	}
}

func TestReplaceEnv(t *testing.T) {
	result := replaceEnv([]string{"A=old", "B=keep"}, map[string]string{"A": "new", "C": "added"})
	values := make(map[string]string)
	for _, entry := range result {
		name, value, _ := strings.Cut(entry, "=")
		values[name] = value
	}
	if values["A"] != "new" || values["B"] != "keep" || values["C"] != "added" {
		t.Fatalf("unexpected environment: %#v", values)
	}
}

func TestManagerStartsAndStopsOwnedProcess(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell helper is Unix-only")
	}
	directory := t.TempDir()
	helper := filepath.Join(directory, "fake-sidecar")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\ntrap 'exit 0' TERM INT\nwhile :; do sleep 1; done\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	var healthChecks atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		status := http.StatusServiceUnavailable
		if healthChecks.Add(1) >= 2 {
			status = http.StatusOK
		}
		return &http.Response{
			StatusCode: status,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(`{"success":true,"data":{"service":"xiaohongshu-mcp"}}`)),
			Request:    request,
		}, nil
	})}
	manager, err := New(Config{
		Endpoint: "http://127.0.0.1:18060", Binary: helper,
		SessionPath: filepath.Join(directory, "session.json"),
		LogPath:     filepath.Join(directory, "sidecar.log"),
		HTTPClient:  client,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := manager.Ensure(ctx); err != nil {
		t.Fatal(err)
	}
	if !manager.Owned() {
		t.Fatal("manager did not own the process it started")
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	if manager.Owned() {
		t.Fatal("manager still owns a process after Close")
	}
}
