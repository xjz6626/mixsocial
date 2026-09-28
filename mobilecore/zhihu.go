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
	"github.com/xjz6626/mixsocial/internal/source/zhihu"
)

type zhihuConfig struct {
	Timeout  string `json:"timeout"`
	PageSize int    `json:"pageSize"`
}

// Zhihu is the gomobile-safe JSON boundary around the pure Go provider.
// Flutter owns durable credential storage; the provider keeps only an
// in-memory cookie jar so credentials never enter ordinary app databases.
type Zhihu struct {
	mu       sync.RWMutex
	provider *zhihu.Provider
	timeout  time.Duration
	pageSize int
	opMu     sync.Mutex
	active   map[string]*activeOperation
}

func NewZhihu(configJSON string) (*Zhihu, error) {
	var config zhihuConfig
	if strings.TrimSpace(configJSON) != "" {
		if err := json.Unmarshal([]byte(configJSON), &config); err != nil {
			return nil, fmt.Errorf("parse Zhihu mobile config: %w", err)
		}
	}
	timeout := 45 * time.Second
	if config.Timeout != "" {
		parsed, err := time.ParseDuration(config.Timeout)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("invalid Zhihu timeout %q", config.Timeout)
		}
		timeout = parsed
	}
	pageSize := config.PageSize
	if pageSize <= 0 {
		pageSize = 10
	}
	if pageSize > 30 {
		return nil, fmt.Errorf("invalid Zhihu page size %d", pageSize)
	}
	core := &Zhihu{
		timeout:  timeout,
		pageSize: pageSize,
		active:   make(map[string]*activeOperation),
	}
	core.resetProvider()
	return core, nil
}

func (z *Zhihu) resetProvider() {
	z.provider = zhihu.New(zhihu.Config{
		Client:   &http.Client{Timeout: z.timeout},
		PageSize: z.pageSize,
	})
}

func (z *Zhihu) BrowseWithRequest(requestID, channel, cursor string) (string, error) {
	parsed := source.Channel(strings.TrimSpace(channel))
	if parsed == "" {
		parsed = source.ChannelRecommend
	}
	ctx, finish := z.begin(requestID)
	defer finish()
	page, err := z.snapshot().Browse(ctx, parsed, cursor)
	return encode(page, err)
}

func (z *Zhihu) SearchWithRequest(requestID, query, cursor string) (string, error) {
	ctx, finish := z.begin(requestID)
	defer finish()
	page, err := z.snapshot().Search(ctx, query, cursor)
	return encode(page, err)
}

func (z *Zhihu) DetailWithRequest(requestID, refJSON string) (string, error) {
	ref, err := zhihuRef(refJSON)
	if err != nil {
		return "", err
	}
	ctx, finish := z.begin(requestID)
	defer finish()
	detail, err := z.snapshot().Detail(ctx, ref)
	return encode(detail, err)
}

func (z *Zhihu) CommentsWithRequest(requestID, refJSON, cursor string) (string, error) {
	ref, err := zhihuRef(refJSON)
	if err != nil {
		return "", err
	}
	ctx, finish := z.begin(requestID)
	defer finish()
	page, err := z.snapshot().Comments(ctx, ref, cursor)
	return encode(page, err)
}

func (z *Zhihu) LikeWithRequest(requestID, refJSON string, value bool) error {
	ref, err := zhihuRef(refJSON)
	if err != nil {
		return err
	}
	ctx, finish := z.begin(requestID)
	defer finish()
	return z.snapshot().Like(ctx, ref, value)
}

func (z *Zhihu) CommentWithRequest(requestID, refJSON, body string) error {
	ref, err := zhihuRef(refJSON)
	if err != nil {
		return err
	}
	ctx, finish := z.begin(requestID)
	defer finish()
	return z.snapshot().Comment(ctx, ref, body)
}

func (z *Zhihu) ReplyWithRequest(requestID, refJSON, commentJSON, body string) error {
	ref, err := zhihuRef(refJSON)
	if err != nil {
		return err
	}
	comment, err := zhihuRef(commentJSON)
	if err != nil {
		return fmt.Errorf("invalid Zhihu comment ref: %w", err)
	}
	ctx, finish := z.begin(requestID)
	defer finish()
	return z.snapshot().Reply(ctx, ref, comment, body)
}

func (z *Zhihu) LoginWithCredentialRequest(requestID, credential string) (string, error) {
	ctx, finish := z.begin(requestID)
	defer finish()
	status, err := z.snapshot().LoginWithCredential(ctx, credential)
	return encode(status, err)
}

func (z *Zhihu) LoginStatusWithRequest(requestID string) (string, error) {
	ctx, finish := z.begin(requestID)
	defer finish()
	status, err := z.snapshot().LoginStatus(ctx)
	return encode(status, err)
}

func (z *Zhihu) ClearCredential() {
	z.mu.Lock()
	previous := z.provider
	z.resetProvider()
	z.mu.Unlock()
	if previous != nil {
		_ = previous.Close()
	}
}

func (z *Zhihu) Cancel(requestID string) {
	if requestID == "" {
		return
	}
	z.opMu.Lock()
	operation := z.active[requestID]
	delete(z.active, requestID)
	z.opMu.Unlock()
	if operation != nil {
		operation.cancel()
	}
}

func (z *Zhihu) Close() {
	z.opMu.Lock()
	operations := z.active
	z.active = make(map[string]*activeOperation)
	z.opMu.Unlock()
	for _, operation := range operations {
		operation.cancel()
	}
	z.mu.Lock()
	provider := z.provider
	z.provider = nil
	z.mu.Unlock()
	if provider != nil {
		_ = provider.Close()
	}
}

func (z *Zhihu) begin(requestID string) (context.Context, func()) {
	ctx, cancel := context.WithTimeout(context.Background(), z.timeout)
	if requestID == "" {
		return ctx, cancel
	}
	operation := &activeOperation{cancel: cancel}
	z.opMu.Lock()
	previous := z.active[requestID]
	z.active[requestID] = operation
	z.opMu.Unlock()
	if previous != nil {
		previous.cancel()
	}
	return ctx, func() {
		cancel()
		z.opMu.Lock()
		if z.active[requestID] == operation {
			delete(z.active, requestID)
		}
		z.opMu.Unlock()
	}
}

func (z *Zhihu) snapshot() *zhihu.Provider {
	z.mu.RLock()
	defer z.mu.RUnlock()
	return z.provider
}

func zhihuRef(value string) (domain.Ref, error) {
	var ref domain.Ref
	if err := json.Unmarshal([]byte(value), &ref); err != nil {
		return domain.Ref{}, fmt.Errorf("parse Zhihu ref: %w", err)
	}
	if ref.Source == "" {
		ref.Source = domain.SourceZhihu
	}
	if ref.Source != domain.SourceZhihu || strings.TrimSpace(ref.ID) == "" {
		return domain.Ref{}, fmt.Errorf("invalid Zhihu ref")
	}
	return ref, nil
}
