package tui

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/xjz6626/mixsocial/internal/domain"
)

const (
	maxMediaPreviews = 9
	maxMediaBytes    = 12 << 20
	maxMediaPixels   = 36_000_000
)

func mergeListMedia(detail *domain.Detail, listItem domain.Item) {
	if detail == nil {
		return
	}
	for _, summaryMedia := range listItem.Media {
		merged := false
		for index := range detail.Media {
			media := &detail.Media[index]
			if media.Kind != summaryMedia.Kind {
				continue
			}
			if media.Kind == "video" {
				if media.PreviewURL == "" {
					media.PreviewURL = summaryMedia.PreviewURL
				}
				if media.Duration == 0 {
					media.Duration = summaryMedia.Duration
				}
				merged = true
				break
			}
			if effectivePreviewURL(*media) == effectivePreviewURL(summaryMedia) {
				merged = true
				break
			}
		}
		if !merged && effectivePreviewURL(summaryMedia) != "" {
			detail.Media = append(detail.Media, summaryMedia)
		}
	}
}

func mediaSummary(media []domain.Media) string {
	var images, videos int
	for _, item := range media {
		switch item.Kind {
		case "video":
			videos++
		case "image":
			images++
		}
	}
	var parts []string
	if images > 0 {
		parts = append(parts, fmt.Sprintf("▧ %d 图", images))
	}
	if videos > 0 {
		parts = append(parts, fmt.Sprintf("▶ %d 视频", videos))
	}
	return strings.Join(parts, "  ")
}

func (m *Model) prepareMediaLoads() []tea.Cmd {
	if m.detail == nil {
		return nil
	}
	ref := m.detail.Ref
	referer := m.detail.Ref.URL
	contentWidth := max(24, m.viewport.Width-4)
	seen := make(map[string]bool)
	var commands []tea.Cmd
	queue := func(media domain.Media, width int) {
		if len(commands) >= maxMediaPreviews {
			return
		}
		rawURL := effectivePreviewURL(media)
		spec := m.nativePreviewSpec(width)
		key := rawURL + fmt.Sprintf("\x00%d\x00%d", spec.columns, spec.rows)
		if rawURL == "" || seen[key] {
			return
		}
		seen[key] = true
		if _, cached := m.mediaCache.native(rawURL, spec); cached {
			return
		}
		m.mediaPreviews[rawURL] = mediaPreview{loading: true}
		commands = append(commands, loadMediaCmd(ref, rawURL, referer, m.timeout, m.mediaCache, spec))
	}
	for _, media := range m.detail.Media {
		queue(media, contentWidth)
	}
	for _, comment := range m.detail.Comments {
		for _, media := range comment.Media {
			queue(media, max(20, contentWidth-3))
		}
	}
	return commands
}

func loadMediaCmd(ref domain.Ref, rawURL, referer string, timeout time.Duration, cache *mediaCache, spec nativePreviewSpec) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), min(timeout, 20*time.Second))
		defer cancel()
		img, err := cache.load(ctx, rawURL, referer)
		if err == nil {
			_, err = cache.renderNative(rawURL, spec)
		}
		return mediaLoadedMsg{ref: ref, url: rawURL, image: img, err: err}
	}
}

func downloadImage(ctx context.Context, rawURL, referer string) (image.Image, error) {
	encoded, err := fetchImageBytes(ctx, rawURL, referer)
	if err != nil {
		return nil, err
	}
	return decodeImageBytes(encoded)
}

func fetchImageBytes(ctx context.Context, rawURL, referer string) ([]byte, error) {
	if safeHTTPURL(rawURL) == "" {
		return nil, fmt.Errorf("不支持的媒体地址")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, fmt.Errorf("创建图片请求: %w", err)
	}
	request.Header.Set("User-Agent", "mixsocial/0.3")
	request.Header.Set("Accept", "image/png,image/jpeg,image/gif;q=0.9,*/*;q=0.1")
	if safeHTTPURL(referer) != "" {
		request.Header.Set("Referer", referer)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("下载预览: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("下载预览: HTTP %d", response.StatusCode)
	}
	if response.ContentLength > maxMediaBytes {
		return nil, fmt.Errorf("图片超过 %d MiB 限制", maxMediaBytes>>20)
	}
	encoded, err := io.ReadAll(io.LimitReader(response.Body, maxMediaBytes+1))
	if err != nil {
		return nil, fmt.Errorf("读取图片: %w", err)
	}
	if len(encoded) > maxMediaBytes {
		return nil, fmt.Errorf("图片超过 %d MiB 限制", maxMediaBytes>>20)
	}
	return encoded, nil
}

func decodeImageBytes(encoded []byte) (image.Image, error) {
	config, _, err := image.DecodeConfig(bytes.NewReader(encoded))
	if err != nil {
		return nil, fmt.Errorf("不支持的图片格式: %w", err)
	}
	if config.Width <= 0 || config.Height <= 0 || int64(config.Width)*int64(config.Height) > maxMediaPixels {
		return nil, fmt.Errorf("图片尺寸过大: %d×%d", config.Width, config.Height)
	}
	img, _, err := image.Decode(bytes.NewReader(encoded))
	if err != nil {
		return nil, fmt.Errorf("解码图片: %w", err)
	}
	return img, nil
}

func (m Model) renderMedia(media domain.Media, index, width int) string {
	kind := "图片"
	if media.Kind == "video" {
		kind = "视频"
	}
	metadata := []string{fmt.Sprintf("%s %d", kind, index+1)}
	if media.Width > 0 && media.Height > 0 {
		metadata = append(metadata, fmt.Sprintf("%d×%d", media.Width, media.Height))
	}
	if media.Duration > 0 {
		metadata = append(metadata, formatMediaDuration(media.Duration))
	}
	if media.Format != "" {
		metadata = append(metadata, truncate(media.Format, 24))
	}
	parts := []string{lipgloss.NewStyle().Foreground(mutedColor).Render(strings.Join(metadata, " · "))}
	previewURL := effectivePreviewURL(media)
	if previewURL != "" {
		preview, known := m.mediaPreviews[previewURL]
		spec := m.nativePreviewSpec(width)
		switch {
		case m.imageConfig.protocol != imageProtocolBlocks:
			if native, cached := m.mediaCache.native(previewURL, spec); cached {
				parts = append(parts, native.display)
			} else if known && preview.error != "" {
				parts = append(parts, lipgloss.NewStyle().Foreground(errorColor).Render("预览加载失败: "+truncate(preview.error, max(20, width-8))))
			} else if !known {
				parts = append(parts, lipgloss.NewStyle().Foreground(mutedColor).Render(fmt.Sprintf("预览未自动加载（每篇最多 %d 项）", maxMediaPreviews)))
			} else {
				parts = append(parts, lipgloss.NewStyle().Foreground(mutedColor).Render("正在准备"+m.imageConfig.protocol.String()+"预览…"))
			}
		case m.imageConfig.protocol == imageProtocolBlocks:
			if rendered, cached := m.mediaCache.native(previewURL, spec); cached {
				parts = append(parts, rendered.display)
			} else if known && preview.error != "" {
				parts = append(parts, lipgloss.NewStyle().Foreground(errorColor).Render("预览加载失败: "+truncate(preview.error, max(20, width-8))))
			} else if known && preview.loading {
				parts = append(parts, lipgloss.NewStyle().Foreground(mutedColor).Render("正在加载预览…"))
			} else {
				parts = append(parts, lipgloss.NewStyle().Foreground(mutedColor).Render(fmt.Sprintf("预览未自动加载（每篇最多 %d 项）", maxMediaPreviews)))
			}
		}
	}
	linkURL := media.URL
	linkLabel := "原图"
	if media.Kind == "video" {
		linkLabel = "视频流"
		if linkURL == "" {
			parts = append(parts, lipgloss.NewStyle().Foreground(mutedColor).Render("视频流地址未返回，仅显示封面"))
		}
	}
	if safe := safeHTTPURL(linkURL); safe != "" {
		label := terminalLink(linkLabel, safe)
		parts = append(parts, lipgloss.NewStyle().Foreground(mutedColor).Render(label+"  "+truncate(safe, max(24, width-8))))
	}
	return strings.Join(parts, "\n")
}

func effectivePreviewURL(media domain.Media) string {
	// Image URLs represent the full-size asset; PreviewURL is primarily a
	// video cover or a list-card fallback. Prefer the original whenever the
	// source exposes one.
	if media.Kind == "image" && media.URL != "" {
		return media.URL
	}
	if media.PreviewURL != "" {
		return media.PreviewURL
	}
	if media.Kind == "image" {
		return media.URL
	}
	return ""
}

func (m Model) nativePreviewSpec(width int) nativePreviewSpec {
	columns, rows := min(64, max(12, width)), 18
	if m.imageConfig.protocol == imageProtocolBlocks {
		columns, rows = min(96, max(12, width)), 28
	}
	return nativePreviewSpec{
		config:  m.imageConfig,
		columns: columns,
		rows:    rows,
	}
}

func (m Model) kittyImagePreamble() string {
	if m.imageConfig.protocol != imageProtocolKitty || m.detail == nil {
		return ""
	}
	width := max(24, m.viewport.Width-4)
	seen := make(map[string]bool)
	var output strings.Builder
	appendMedia := func(media domain.Media, mediaWidth int) {
		rawURL := effectivePreviewURL(media)
		spec := m.nativePreviewSpec(mediaWidth)
		key := rawURL + fmt.Sprintf("\x00%d\x00%d", spec.columns, spec.rows)
		if rawURL == "" || seen[key] {
			return
		}
		seen[key] = true
		if preview, ok := m.mediaCache.native(rawURL, spec); ok {
			output.WriteString(preview.transmit)
		}
	}
	for _, media := range m.detail.Media {
		appendMedia(media, width)
	}
	for _, comment := range m.detail.Comments {
		for _, media := range comment.Media {
			appendMedia(media, max(20, width-3))
		}
	}
	return output.String()
}

func formatMediaDuration(duration time.Duration) string {
	duration = duration.Round(time.Second)
	if duration < time.Minute {
		return fmt.Sprintf("%d 秒", max(1, int(duration.Seconds())))
	}
	return fmt.Sprintf("%d:%02d", int(duration.Minutes()), int(duration.Seconds())%60)
}

func safeHTTPURL(rawURL string) string {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return ""
	}
	if strings.ContainsAny(rawURL, "\x00\x1b\r\n") {
		return ""
	}
	return parsed.String()
}

func terminalLink(label, rawURL string) string {
	if safeHTTPURL(rawURL) == "" {
		return label
	}
	return "\x1b]8;;" + rawURL + "\x1b\\" + label + "\x1b]8;;\x1b\\"
}

// renderTerminalImage produces a portable true-color half-block preview. It
// does not depend on Kitty/iTerm/Sixel support, so it also works over SSH and
// inside common terminal multiplexers.
func renderTerminalImage(img image.Image, maxWidth, maxRows int) string {
	if img == nil || maxWidth < 1 || maxRows < 1 {
		return ""
	}
	bounds := img.Bounds()
	if bounds.Empty() {
		return ""
	}
	targetWidth := min(bounds.Dx(), maxWidth)
	targetRows := max(1, (bounds.Dy()*targetWidth+bounds.Dx()*2-1)/(bounds.Dx()*2))
	if targetRows > maxRows {
		targetRows = maxRows
		targetWidth = max(1, min(targetWidth, targetRows*2*bounds.Dx()/bounds.Dy()))
	}
	sampled := resizeTerminalImage(img, targetWidth, targetRows*2)
	bounds = sampled.Bounds()
	var output strings.Builder
	for row := 0; row < targetRows; row++ {
		for x := 0; x < targetWidth; x++ {
			sourceX := bounds.Min.X + x
			topY := bounds.Min.Y + row*2
			bottomY := topY + 1
			tr, tg, tb := terminalRGB(sampled.At(sourceX, topY))
			br, bg, bb := terminalRGB(sampled.At(sourceX, bottomY))
			fmt.Fprintf(&output, "\x1b[38;2;%d;%d;%dm\x1b[48;2;%d;%d;%dm▀", tr, tg, tb, br, bg, bb)
		}
		output.WriteString("\x1b[0m")
		if row+1 < targetRows {
			output.WriteByte('\n')
		}
	}
	return output.String()
}

func terminalRGB(value interface{ RGBA() (r, g, b, a uint32) }) (uint8, uint8, uint8) {
	r, g, b, a := value.RGBA()
	// RGBA returns alpha-premultiplied channels. Composite transparent pixels
	// over white so logos and screenshots remain visible in both light and dark terminals.
	r += 0xffff - a
	g += 0xffff - a
	b += 0xffff - a
	return uint8(min(uint32(0xffff), r) >> 8), uint8(min(uint32(0xffff), g) >> 8), uint8(min(uint32(0xffff), b) >> 8)
}
