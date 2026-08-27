// Package mobilecore exposes a gomobile-friendly JSON boundary around the
// existing Go sources. Only strings, integers, booleans, byte slices and
// exported concrete types should cross this package boundary.
package mobilecore

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
	"github.com/xjz6626/mixsocial/internal/source/tieba"
)

type tiebaConfig struct {
	Forums  []string `json:"forums"`
	Timeout string   `json:"timeout"`
}

// Tieba is safe for calls from platform-channel worker threads. Login state is
// intentionally kept in memory: the Flutter layer stores the imported BDUSS in
// Android Keystore / Apple Keychain and restores it after process startup.
type Tieba struct {
	mu       sync.RWMutex
	provider *tieba.Provider
	timeout  time.Duration
	forums   []string
	opMu     sync.Mutex
	active   map[string]*activeOperation
}

type activeOperation struct {
	cancel context.CancelFunc
}

func NewTieba(configJSON string) (*Tieba, error) {
	var config tiebaConfig
	if strings.TrimSpace(configJSON) != "" {
		if err := json.Unmarshal([]byte(configJSON), &config); err != nil {
			return nil, fmt.Errorf("parse Tieba mobile config: %w", err)
		}
	}
	timeout := 45 * time.Second
	if config.Timeout != "" {
		parsed, err := time.ParseDuration(config.Timeout)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("invalid Tieba timeout %q", config.Timeout)
		}
		timeout = parsed
	}
	core := &Tieba{
		timeout: timeout,
		forums:  append([]string(nil), config.Forums...),
		active:  make(map[string]*activeOperation),
	}
	core.resetProvider()
	return core, nil
}

func (t *Tieba) resetProvider() {
	t.provider = tieba.New(tieba.Config{
		Client: &http.Client{Timeout: t.timeout},
		Forums: append([]string(nil), t.forums...),
		// BrowserPath and SessionPath stay empty on mobile. Login is owned by the
		// visible WebView / secure Flutter storage rather than Rod or a JSON file.
	})
}

func (t *Tieba) Browse(channel, cursor string) (string, error) {
	return t.BrowseWithRequest("", channel, cursor)
}

func (t *Tieba) BrowseWithRequest(requestID, channel, cursor string) (string, error) {
	provider := t.snapshot()
	parsed := source.Channel(strings.TrimSpace(channel))
	if parsed == "" {
		parsed = source.ChannelRecommend
	}
	ctx, finish := t.begin(requestID)
	defer finish()
	page, err := provider.Browse(ctx, parsed, cursor)
	return encode(page, err)
}

func (t *Tieba) Search(query, cursor string) (string, error) {
	return t.SearchWithRequest("", query, cursor)
}

func (t *Tieba) SearchWithRequest(requestID, query, cursor string) (string, error) {
	provider := t.snapshot()
	ctx, finish := t.begin(requestID)
	defer finish()
	page, err := provider.Search(ctx, query, cursor)
	return encode(page, err)
}

func (t *Tieba) Detail(refJSON string) (string, error) {
	return t.DetailWithRequest("", refJSON)
}

func (t *Tieba) DetailWithRequest(requestID, refJSON string) (string, error) {
	var ref domain.Ref
	if err := json.Unmarshal([]byte(refJSON), &ref); err != nil {
		return "", fmt.Errorf("parse Tieba ref: %w", err)
	}
	if ref.Source == "" {
		ref.Source = domain.SourceTieba
	}
	if ref.Source != domain.SourceTieba || strings.TrimSpace(ref.ID) == "" {
		return "", fmt.Errorf("invalid Tieba ref")
	}
	provider := t.snapshot()
	ctx, finish := t.begin(requestID)
	defer finish()
	detail, err := provider.Detail(ctx, ref)
	return encode(detail, err)
}

func (t *Tieba) LoginWithCredential(credential string) (string, error) {
	return t.LoginWithCredentialRequest("", credential)
}

func (t *Tieba) LoginWithCredentialRequest(requestID, credential string) (string, error) {
	provider := t.snapshot()
	ctx, finish := t.begin(requestID)
	defer finish()
	status, err := provider.LoginWithCredential(ctx, credential)
	return encode(status, err)
}

func (t *Tieba) ClearCredential() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.resetProvider()
}

// Cancel interrupts a single in-flight request. An empty request ID is used by
// the compatibility methods above and is deliberately not registered.
func (t *Tieba) Cancel(requestID string) {
	if requestID == "" {
		return
	}
	t.opMu.Lock()
	operation := t.active[requestID]
	delete(t.active, requestID)
	t.opMu.Unlock()
	if operation != nil {
		operation.cancel()
	}
}

// Close releases all request contexts when Flutter detaches the engine.
func (t *Tieba) Close() {
	t.opMu.Lock()
	operations := t.active
	t.active = make(map[string]*activeOperation)
	t.opMu.Unlock()
	for _, operation := range operations {
		operation.cancel()
	}
}

func (t *Tieba) begin(requestID string) (context.Context, func()) {
	ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
	if requestID == "" {
		return ctx, cancel
	}
	operation := &activeOperation{cancel: cancel}
	t.opMu.Lock()
	previous := t.active[requestID]
	t.active[requestID] = operation
	t.opMu.Unlock()
	if previous != nil {
		previous.cancel()
	}
	return ctx, func() {
		cancel()
		t.opMu.Lock()
		if t.active[requestID] == operation {
			delete(t.active, requestID)
		}
		t.opMu.Unlock()
	}
}

func (t *Tieba) snapshot() *tieba.Provider {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.provider
}

func encode(value any, err error) (string, error) {
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return string(encoded), nil
}
