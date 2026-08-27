package tui

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/xjz6626/mixsocial/internal/domain"
)

const (
	detailPrefetchConcurrency = 3
	mediaPrefetchConcurrency  = 3
)

type detailLoadResult struct {
	detail domain.Detail
	err    error
}

type detailLoadFlight struct {
	done chan struct{}
	detailLoadResult
}

type detailLoader struct {
	mu         sync.Mutex
	generation int
	results    map[string]detailLoadResult
	flights    map[string]*detailLoadFlight
}

func newDetailLoader() *detailLoader {
	return &detailLoader{results: make(map[string]detailLoadResult), flights: make(map[string]*detailLoadFlight)}
}

func (loader *detailLoader) reset(generation int) {
	loader.mu.Lock()
	loader.generation = generation
	loader.results = make(map[string]detailLoadResult)
	loader.mu.Unlock()
}

func (loader *detailLoader) load(ctx context.Context, generation int, key string, fetch func() (domain.Detail, error)) (domain.Detail, error) {
	flightKey := fmt.Sprintf("%d\x00%s", generation, key)
	loader.mu.Lock()
	if result, ok := loader.results[flightKey]; ok {
		loader.mu.Unlock()
		return result.detail, result.err
	}
	if flight, ok := loader.flights[flightKey]; ok {
		loader.mu.Unlock()
		select {
		case <-flight.done:
			return flight.detail, flight.err
		case <-ctx.Done():
			return domain.Detail{}, ctx.Err()
		}
	}
	flight := &detailLoadFlight{done: make(chan struct{})}
	loader.flights[flightKey] = flight
	loader.mu.Unlock()

	detail, err := fetch()
	loader.mu.Lock()
	flight.detail, flight.err = detail, err
	delete(loader.flights, flightKey)
	if loader.generation == generation && err == nil {
		loader.results[flightKey] = detailLoadResult{detail: detail, err: err}
	}
	close(flight.done)
	loader.mu.Unlock()
	return detail, err
}

func refCacheKey(ref domain.Ref) string {
	return strings.Join([]string{string(ref.Source), ref.ID, ref.ParentID, ref.Token}, "\x00")
}

func mediaTaskKey(task mediaPrefetchTask) string {
	return fmt.Sprintf("%s\x00%d\x00%d\x00%d", task.url, task.spec.config.protocol, task.spec.columns, task.spec.rows)
}

func (m *Model) beginPagePrefetch(items []domain.Item) []tea.Cmd {
	m.prefetchGeneration++
	m.detailLoader.reset(m.prefetchGeneration)
	m.detailCache = make(map[string]domain.Detail)
	m.detailPrefetchQueue = nil
	m.detailPrefetchQueued = make(map[string]bool)
	m.detailPrefetching = make(map[string]bool)
	m.detailPrefetchActive = 0
	m.detailPrefetchTotal = 0
	m.detailPrefetchDone = 0
	m.detailPrefetchFailed = 0
	m.mediaPrefetchQueue = nil
	m.mediaPrefetchKnown = make(map[string]bool)
	m.mediaPrefetchActive = 0
	m.mediaPrefetchTotal = 0
	m.mediaPrefetchDone = 0
	m.mediaPrefetchFailed = 0

	for _, item := range items {
		key := refCacheKey(item.Ref)
		if item.Ref.Source == "" || item.Ref.ID == "" || m.detailPrefetchQueued[key] {
			continue
		}
		m.detailPrefetchQueue = append(m.detailPrefetchQueue, item)
		m.detailPrefetchQueued[key] = true
		m.detailPrefetchTotal++
	}
	return m.startDetailPrefetches()
}

func (m *Model) startDetailPrefetches() []tea.Cmd {
	var commands []tea.Cmd
	for m.detailPrefetchActive < detailPrefetchConcurrency && len(m.detailPrefetchQueue) > 0 {
		item := m.detailPrefetchQueue[0]
		m.detailPrefetchQueue = m.detailPrefetchQueue[1:]
		key := refCacheKey(item.Ref)
		delete(m.detailPrefetchQueued, key)
		m.detailPrefetching[key] = true
		m.detailPrefetchActive++
		commands = append(commands, m.prefetchDetailCmd(m.prefetchGeneration, item))
	}
	return commands
}

func (m Model) prefetchDetailCmd(generation int, item domain.Item) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
		defer cancel()
		detail, err := m.detailLoader.load(ctx, generation, refCacheKey(item.Ref), func() (domain.Detail, error) {
			loaded, loadErr := m.mixed.Detail(ctx, item.Ref)
			if loadErr == nil {
				mergeListMedia(&loaded, item)
			}
			return loaded, loadErr
		})
		return prefetchDetailMsg{generation: generation, item: item, detail: detail, err: err}
	}
}

func (m *Model) removeQueuedDetail(key string) bool {
	if !m.detailPrefetchQueued[key] {
		return false
	}
	for index, item := range m.detailPrefetchQueue {
		if refCacheKey(item.Ref) != key {
			continue
		}
		m.detailPrefetchQueue = append(m.detailPrefetchQueue[:index], m.detailPrefetchQueue[index+1:]...)
		delete(m.detailPrefetchQueued, key)
		return true
	}
	delete(m.detailPrefetchQueued, key)
	return false
}

func (m *Model) enqueueDetailMedia(detail domain.Detail) {
	width := 64
	if m.viewportReady {
		width = max(24, m.viewport.Width-4)
	}
	count := 0
	queue := func(media domain.Media, mediaWidth int) {
		if count >= maxMediaPreviews {
			return
		}
		rawURL := effectivePreviewURL(media)
		if rawURL == "" {
			return
		}
		spec := m.nativePreviewSpec(mediaWidth)
		task := mediaPrefetchTask{
			generation: m.prefetchGeneration,
			ref:        detail.Ref,
			url:        rawURL,
			referer:    detail.Ref.URL,
			spec:       spec,
		}
		key := mediaTaskKey(task)
		if m.mediaPrefetchKnown[key] {
			return
		}
		if _, cached := m.mediaCache.native(rawURL, spec); cached {
			m.mediaPrefetchKnown[key] = true
			return
		}
		m.mediaPrefetchKnown[key] = true
		m.mediaPrefetchQueue = append(m.mediaPrefetchQueue, task)
		m.mediaPrefetchTotal++
		count++
	}
	for _, media := range detail.Media {
		queue(media, width)
	}
	for _, comment := range detail.Comments {
		for _, media := range comment.Media {
			queue(media, max(20, width-3))
		}
	}
}

func (m *Model) startMediaPrefetches() []tea.Cmd {
	var commands []tea.Cmd
	for m.mediaPrefetchActive < mediaPrefetchConcurrency && len(m.mediaPrefetchQueue) > 0 {
		task := m.mediaPrefetchQueue[0]
		m.mediaPrefetchQueue = m.mediaPrefetchQueue[1:]
		m.mediaPrefetchActive++
		commands = append(commands, m.prefetchMediaCmd(task))
	}
	return commands
}

func (m Model) prefetchMediaCmd(task mediaPrefetchTask) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), min(m.timeout, 20*time.Second))
		defer cancel()
		_, err := m.mediaCache.load(ctx, task.url, task.referer)
		if err == nil {
			_, err = m.mediaCache.renderNative(task.url, task.spec)
		}
		return prefetchMediaMsg{task: task, err: err}
	}
}

func (m *Model) updatePrefetchStatus() {
	if m.mode != listView || m.busy || m.pageStatus == "" {
		return
	}
	detailRemaining := m.detailPrefetchTotal - m.detailPrefetchDone
	mediaRemaining := m.mediaPrefetchTotal - m.mediaPrefetchDone
	switch {
	case detailRemaining > 0 || mediaRemaining > 0:
		m.status = fmt.Sprintf("%s · 后台缓存 详情 %d/%d · 媒体 %d/%d",
			m.pageStatus,
			m.detailPrefetchDone, m.detailPrefetchTotal,
			m.mediaPrefetchDone, m.mediaPrefetchTotal,
		)
	case m.detailPrefetchTotal > 0:
		m.status = fmt.Sprintf("%s · 已缓存 %d 个话题", m.pageStatus, m.detailPrefetchTotal-m.detailPrefetchFailed)
		if failures := m.detailPrefetchFailed + m.mediaPrefetchFailed; failures > 0 {
			m.status += fmt.Sprintf("（%d 项失败，进入时重试）", failures)
		}
	default:
		m.status = m.pageStatus
	}
}
