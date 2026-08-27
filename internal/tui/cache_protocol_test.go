package tui

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
)

func TestDetectTerminalImageProtocol(t *testing.T) {
	tests := []struct {
		name     string
		env      map[string]string
		protocol imageProtocol
		pass     imagePassthrough
	}{
		{name: "kitty", env: map[string]string{"KITTY_WINDOW_ID": "1"}, protocol: imageProtocolKitty},
		{name: "iterm", env: map[string]string{"TERM_PROGRAM": "iTerm.app"}, protocol: imageProtocolITerm2},
		{name: "sixel", env: map[string]string{"TERM": "xterm-sixel"}, protocol: imageProtocolSixel},
		{name: "override", env: map[string]string{"KITTY_WINDOW_ID": "1", "MIXSOCIAL_IMAGE_PROTOCOL": "blocks"}, protocol: imageProtocolBlocks},
		{name: "tmux fallback", env: map[string]string{"TERM_PROGRAM": "WezTerm", "TMUX": "/tmp/tmux"}, protocol: imageProtocolBlocks, pass: imagePassthroughTmux},
		{name: "tmux opt in", env: map[string]string{"MIXSOCIAL_IMAGE_PROTOCOL": "kitty", "TMUX": "/tmp/tmux"}, protocol: imageProtocolKitty, pass: imagePassthroughTmux},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			config := detectTerminalImageConfig(func(key string) string { return test.env[key] })
			if config.protocol != test.protocol || config.passthrough != test.pass {
				t.Fatalf("config = %+v", config)
			}
		})
	}
}

func TestNativeImageProtocolsReserveTerminalCells(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 40, 80))
	for y := range 80 {
		for x := range 40 {
			img.SetNRGBA(x, y, color.NRGBA{R: uint8(x * 6), G: uint8(y * 3), B: 120, A: 255})
		}
	}
	for _, protocol := range []imageProtocol{imageProtocolKitty, imageProtocolITerm2, imageProtocolSixel} {
		t.Run(protocol.String(), func(t *testing.T) {
			preview, err := renderNativeImage(img, terminalImageConfig{protocol: protocol}, 8, 4, "https://img.test/one")
			if err != nil {
				t.Fatal(err)
			}
			lines := strings.Split(preview.display, "\n")
			if len(lines) != preview.rows || preview.rows != 4 || preview.columns != 4 {
				t.Fatalf("preview size = %dx%d, lines = %d", preview.columns, preview.rows, len(lines))
			}
			if width := ansi.StringWidth(lines[0]); width != preview.columns {
				t.Fatalf("reserved image width = %d, want %d", width, preview.columns)
			}
			switch protocol {
			case imageProtocolKitty:
				if !strings.Contains(preview.transmit, "\x1b_G") || !strings.ContainsRune(preview.display, '\U0010EEEE') {
					t.Fatalf("missing Kitty sequences: transmit=%q display=%q", preview.transmit, preview.display)
				}
			case imageProtocolITerm2:
				if !strings.Contains(preview.display, "\x1b]1337;File=") {
					t.Fatalf("missing iTerm2 sequence: %q", preview.display)
				}
			case imageProtocolSixel:
				if !strings.Contains(preview.display, "\x1bP0;1q") {
					t.Fatalf("missing Sixel sequence: %q", preview.display)
				}
			}
		})
	}
}

func TestNativeImagePreparationKeepsHiDPIDetail(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 1000, 600))
	highDPI := prepareNativeImage(img, imageProtocolKitty, 40, 12).Bounds()
	if highDPI.Dx() != 960 || highDPI.Dy() != 576 {
		t.Fatalf("Kitty prepared image = %dx%d, want 960x576", highDPI.Dx(), highDPI.Dy())
	}
	sixel := prepareNativeImage(img, imageProtocolSixel, 40, 12).Bounds()
	if sixel.Dx() != 400 || sixel.Dy() != 240 {
		t.Fatalf("Sixel prepared image = %dx%d, want 400x240", sixel.Dx(), sixel.Dy())
	}
}

func TestImagePreviewPrefersOriginalAndANSIUsesAvailableWidth(t *testing.T) {
	media := domain.Media{Kind: "image", URL: "https://img.test/original.png", PreviewURL: "https://img.test/thumb.png"}
	if got := effectivePreviewURL(media); got != media.URL {
		t.Fatalf("preview URL = %q, want original %q", got, media.URL)
	}
	video := domain.Media{Kind: "video", URL: "https://video.test/stream", PreviewURL: "https://img.test/cover.png"}
	if got := effectivePreviewURL(video); got != video.PreviewURL {
		t.Fatalf("video preview URL = %q, want cover %q", got, video.PreviewURL)
	}

	img := image.NewNRGBA(image.Rect(0, 0, 200, 100))
	rendered := renderTerminalImage(img, 80, 28)
	lines := strings.Split(rendered, "\n")
	if len(lines) != 20 || ansi.StringWidth(lines[0]) != 80 {
		t.Fatalf("ANSI preview = %d rows x %d columns, want 20x80", len(lines), ansi.StringWidth(lines[0]))
	}
}

func TestExplicitImageProtocolAndVisibleStatus(t *testing.T) {
	model := New(source.NewMixed(&prefetchTestProvider{}), time.Second)
	if err := model.SetImageProtocol("kitty"); err != nil {
		t.Fatal(err)
	}
	if model.imageConfig.protocol != imageProtocolKitty {
		t.Fatalf("protocol = %s, want Kitty", model.imageConfig.protocol)
	}
	model.resize(100, 30)
	if view := model.View(); !strings.Contains(view, "图片 Kitty") {
		t.Fatalf("view does not expose active image protocol: %q", view)
	}
	if err := model.SetImageProtocol("made-up"); err == nil {
		t.Fatal("invalid image protocol was accepted")
	}
}

func TestMediaCacheUsesDiskWithoutRedownloading(t *testing.T) {
	encoded := testPNG(t, 32, 24)
	requests := 0
	oldClient := http.DefaultClient
	http.DefaultClient = &http.Client{Transport: mediaRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		requests++
		return imageResponse(request, encoded), nil
	})}
	defer func() { http.DefaultClient = oldClient }()

	directory := t.TempDir()
	first := newMediaCache()
	first.directory = directory
	if _, err := first.load(context.Background(), "https://img.test/cached.png", ""); err != nil {
		t.Fatal(err)
	}
	second := newMediaCache()
	second.directory = directory
	if _, err := second.load(context.Background(), "https://img.test/cached.png", ""); err != nil {
		t.Fatal(err)
	}
	if requests != 1 {
		t.Fatalf("media requests = %d, want 1", requests)
	}
}

func TestMediaCacheDoesNotCollapseNativeSourceTo640x360(t *testing.T) {
	encoded := testPNG(t, 1000, 700)
	oldClient := http.DefaultClient
	http.DefaultClient = &http.Client{Transport: mediaRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		return imageResponse(request, encoded), nil
	})}
	defer func() { http.DefaultClient = oldClient }()

	cache := newMediaCache()
	cache.directory = t.TempDir()
	img, err := cache.load(context.Background(), "https://img.test/large.png", "")
	if err != nil {
		t.Fatal(err)
	}
	if bounds := img.Bounds(); bounds.Dx() != 1000 || bounds.Dy() != 700 {
		t.Fatalf("cached image = %dx%d, want 1000x700", bounds.Dx(), bounds.Dy())
	}
}

func TestMediaCacheMemoizesANSIOutput(t *testing.T) {
	cache := newMediaCache()
	cache.directory = ""
	cache.put("https://img.test/ansi.png", image.NewNRGBA(image.Rect(0, 0, 200, 100)))
	spec := nativePreviewSpec{config: terminalImageConfig{protocol: imageProtocolBlocks}, columns: 80, rows: 28}
	first, err := cache.renderNative("https://img.test/ansi.png", spec)
	if err != nil {
		t.Fatal(err)
	}
	second, ok := cache.native("https://img.test/ansi.png", spec)
	if !ok || first.display == "" || second.display != first.display {
		t.Fatal("ANSI render was not memoized")
	}
	if first.columns != 80 || first.rows != 20 {
		t.Fatalf("ANSI cached size = %dx%d, want 80x20", first.columns, first.rows)
	}
}

type prefetchTestProvider struct {
	mu      sync.Mutex
	items   []domain.Item
	details map[string]domain.Detail
	calls   map[string]int
}

func (p *prefetchTestProvider) ID() domain.SourceID { return domain.SourceDemo }
func (p *prefetchTestProvider) Name() string        { return "prefetch test" }
func (p *prefetchTestProvider) Capabilities() source.Capability {
	return source.CapabilityFeed | source.CapabilitySearch | source.CapabilityDetail
}
func (p *prefetchTestProvider) Feed(context.Context, string) (domain.Page, error) {
	return domain.Page{Items: p.items}, nil
}
func (p *prefetchTestProvider) Search(context.Context, string, string) (domain.Page, error) {
	return domain.Page{Items: p.items}, nil
}
func (p *prefetchTestProvider) Detail(_ context.Context, ref domain.Ref) (domain.Detail, error) {
	p.mu.Lock()
	p.calls[ref.ID]++
	p.mu.Unlock()
	return p.details[ref.ID], nil
}

func TestPagePrefetchCachesEveryTopicAndItsMedia(t *testing.T) {
	encoded := testPNG(t, 48, 36)
	mediaRequests := 0
	oldClient := http.DefaultClient
	http.DefaultClient = &http.Client{Transport: mediaRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		mediaRequests++
		return imageResponse(request, encoded), nil
	})}
	defer func() { http.DefaultClient = oldClient }()

	provider := &prefetchTestProvider{details: make(map[string]domain.Detail), calls: make(map[string]int)}
	for _, id := range []string{"one", "two", "three", "four"} {
		item := domain.Item{Ref: domain.Ref{Source: domain.SourceDemo, ID: id, URL: "https://post.test/" + id}, Title: id}
		provider.items = append(provider.items, item)
		item.Media = []domain.Media{{Kind: "image", URL: "https://img.test/" + id + ".png", PreviewURL: "https://img.test/" + id + ".png"}}
		provider.details[id] = domain.Detail{Item: item, Body: "body " + id}
	}

	model := New(source.NewMixed(provider), 2*time.Second)
	model.imageConfig = terminalImageConfig{protocol: imageProtocolBlocks}
	model.mediaCache.directory = t.TempDir()
	model.resize(100, 36)
	page := model.Init()().(pageMsg)
	updated, command := model.Update(page)
	model = drainModelCommands(t, updated.(Model), command)

	if len(model.detailCache) != len(provider.items) || model.detailPrefetchDone != len(provider.items) {
		t.Fatalf("detail cache = %d, progress = %d/%d", len(model.detailCache), model.detailPrefetchDone, model.detailPrefetchTotal)
	}
	if mediaRequests != len(provider.items) || model.mediaPrefetchDone != len(provider.items) {
		t.Fatalf("media cache requests = %d, progress = %d/%d", mediaRequests, model.mediaPrefetchDone, model.mediaPrefetchTotal)
	}
	for _, item := range provider.items {
		if provider.calls[item.Ref.ID] != 1 {
			t.Fatalf("detail %s fetched %d times", item.Ref.ID, provider.calls[item.Ref.ID])
		}
		if _, cached := model.mediaCache.get("https://img.test/" + item.Ref.ID + ".png"); !cached {
			t.Fatalf("media %s was not cached", item.Ref.ID)
		}
	}

	model.selected = len(model.items) - 1
	updated, command = model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(Model)
	if model.mode != detailView || command != nil {
		t.Fatalf("cached topic did not open immediately: mode=%d commandNil=%v", model.mode, command == nil)
	}
}

func drainModelCommands(t *testing.T, model Model, initial tea.Cmd) Model {
	t.Helper()
	queue := []tea.Cmd{initial}
	for steps := 0; len(queue) > 0; steps++ {
		if steps > 1000 {
			t.Fatal("command queue did not drain")
		}
		command := queue[0]
		queue = queue[1:]
		if command == nil {
			continue
		}
		message := command()
		if batch, ok := message.(tea.BatchMsg); ok {
			queue = append(queue, batch...)
			continue
		}
		updated, next := model.Update(message)
		model = updated.(Model)
		if next != nil {
			queue = append(queue, next)
		}
	}
	return model
}

func testPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := range height {
		for x := range width {
			img.SetNRGBA(x, y, color.NRGBA{R: uint8(x), G: uint8(y), B: 90, A: 255})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		t.Fatal(err)
	}
	return encoded.Bytes()
}

func imageResponse(request *http.Request, encoded []byte) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"image/png"}},
		Body:       io.NopCloser(bytes.NewReader(encoded)),
		Request:    request,
	}
}
