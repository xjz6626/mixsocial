package tui

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/liyue201/goqr"
	"github.com/makiuchi-d/gozxing"
	zxingqrcode "github.com/makiuchi-d/gozxing/qrcode"
	qrcode "github.com/skip2/go-qrcode"
	_ "golang.org/x/image/webp"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
)

var (
	accent      = lipgloss.AdaptiveColor{Light: "#A43863", Dark: "#FF7AAE"}
	tiebaColor  = lipgloss.AdaptiveColor{Light: "#2457A6", Dark: "#6FA8FF"}
	xhsColor    = lipgloss.AdaptiveColor{Light: "#B4232C", Dark: "#FF6570"}
	mutedColor  = lipgloss.AdaptiveColor{Light: "#666666", Dark: "#969696"}
	textColor   = lipgloss.AdaptiveColor{Light: "#202020", Dark: "#E8E8E8"}
	borderColor = lipgloss.AdaptiveColor{Light: "#C9C9C9", Dark: "#4A4A4A"}
	errorColor  = lipgloss.AdaptiveColor{Light: "#A11A1A", Dark: "#FF6B6B"}
)

type viewMode int

const (
	listView viewMode = iota
	detailView
	loginView
)

type inputMode int

const (
	inputNone inputMode = iota
	inputSearch
	inputComment
	inputReply
	inputTiebaCredential
)

type actionKind int

const (
	actionLike actionKind = iota
	actionFavorite
	actionComment
	actionReply
)

type pendingAction struct {
	kind    actionKind
	ref     domain.Ref
	comment domain.Ref
	value   bool
	body    string
}

type pageMsg struct {
	page  domain.Page
	err   error
	query string
}

type detailMsg struct {
	detail     domain.Detail
	item       domain.Item
	generation int
	prefetched bool
	err        error
}

type prefetchDetailMsg struct {
	generation int
	item       domain.Item
	detail     domain.Detail
	err        error
}

type mediaPrefetchTask struct {
	generation int
	ref        domain.Ref
	url        string
	referer    string
	spec       nativePreviewSpec
}

type prefetchMediaMsg struct {
	task mediaPrefetchTask
	err  error
}

type mediaLoadedMsg struct {
	ref   domain.Ref
	url   string
	image image.Image
	err   error
}

type mediaPreview struct {
	image   image.Image
	error   string
	loading bool
}

type actionMsg struct {
	action pendingAction
	err    error
}

type loginQRMsg struct {
	challenge source.LoginChallenge
	err       error
}

type loginPollMsg struct{}

type loginStatusMsg struct {
	status source.LoginStatus
	err    error
}

type credentialLoginMsg struct {
	status source.LoginStatus
	err    error
}

type Model struct {
	mixed   *source.Mixed
	timeout time.Duration

	width  int
	height int
	mode   viewMode
	busy   bool

	filters      []domain.SourceID
	filterIndex  int
	channels     []source.Channel
	channelIndex int
	items        []domain.Item
	selected     int
	query        string
	status       string
	notices      []string

	input     textinput.Model
	inputMode inputMode
	pending   *pendingAction

	detail          *domain.Detail
	commentSelected int
	viewport        viewport.Model
	viewportReady   bool
	mediaPreviews   map[string]mediaPreview
	mediaLoading    int
	mediaFailed     int
	mediaCache      *mediaCache
	imageConfig     terminalImageConfig

	detailCache          map[string]domain.Detail
	detailLoader         *detailLoader
	prefetchGeneration   int
	detailPrefetchQueue  []domain.Item
	detailPrefetchQueued map[string]bool
	detailPrefetching    map[string]bool
	detailPrefetchActive int
	detailPrefetchTotal  int
	detailPrefetchDone   int
	detailPrefetchFailed int
	mediaPrefetchQueue   []mediaPrefetchTask
	mediaPrefetchKnown   map[string]bool
	mediaPrefetchActive  int
	mediaPrefetchTotal   int
	mediaPrefetchDone    int
	mediaPrefetchFailed  int
	pageStatus           string

	loginImage     []byte
	loginExpiresAt time.Time
	loginSource    domain.SourceID

	reloadAfterBusy bool
	loginAfterBusy  bool
}

func New(mixed *source.Mixed, timeout time.Duration) Model {
	if timeout <= 0 {
		timeout = 45 * time.Second
	}
	input := textinput.New()
	input.Prompt = "搜索 › "
	input.Placeholder = "贴吧吧名 / 小红书关键词"
	input.CharLimit = 120

	model := Model{
		mixed: mixed, timeout: timeout, input: input, status: "正在加载推荐频道…",
		channels:             []source.Channel{source.ChannelRecommend, source.ChannelHot, source.ChannelFollowing},
		mediaPreviews:        make(map[string]mediaPreview),
		mediaCache:           newMediaCache(),
		imageConfig:          detectTerminalImageConfig(os.Getenv),
		detailCache:          make(map[string]domain.Detail),
		detailLoader:         newDetailLoader(),
		detailPrefetchQueued: make(map[string]bool),
		detailPrefetching:    make(map[string]bool),
		mediaPrefetchKnown:   make(map[string]bool),
	}
	model.filters = append(model.filters, "")
	for _, reader := range mixed.Sources() {
		model.filters = append(model.filters, reader.ID())
	}
	return model
}

// SetImageProtocol applies an explicit image protocol while retaining any
// tmux/Screen passthrough detected from the process environment. An empty or
// "auto" value restores automatic detection.
func (m *Model) SetImageProtocol(value string) error {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" || value == "auto" {
		m.imageConfig = detectTerminalImageConfig(os.Getenv)
		return nil
	}
	switch value {
	case "kitty", "iterm", "iterm2", "sixel", "ansi", "blocks", "none", "off":
	default:
		return fmt.Errorf("不支持的图片协议 %q（可选 auto、kitty、iterm2、sixel、blocks）", value)
	}
	m.imageConfig = detectTerminalImageConfig(func(key string) string {
		if key == "MIXSOCIAL_IMAGE_PROTOCOL" {
			return value
		}
		return os.Getenv(key)
	})
	return nil
}

func (m Model) Init() tea.Cmd {
	return m.feedCmd()
}

func (m Model) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := message.(type) {
	case tea.WindowSizeMsg:
		m.resize(msg.Width, msg.Height)
		if m.mode == detailView && m.detail != nil {
			commands := m.prepareMediaLoads()
			m.mediaLoading += len(commands)
			return m, tea.Batch(commands...)
		}
		return m, nil
	case pageMsg:
		m.busy = false
		m.items = msg.page.Items
		m.notices = msg.page.Notices
		m.selected = clamp(m.selected, 0, max(0, len(m.items)-1))
		m.query = msg.query
		if msg.err != nil {
			m.status = msg.err.Error()
		} else if len(m.items) == 0 {
			m.status = "没有找到条目"
		} else if msg.query != "" {
			m.status = fmt.Sprintf("“%s” · %d 条", msg.query, len(m.items))
		} else {
			m.status = fmt.Sprintf("%s · %d 条", m.currentChannel().Label(), len(m.items))
		}
		m.pageStatus = m.status
		if m.loginAfterBusy {
			m.beginPagePrefetch(nil)
			m.loginAfterBusy = false
			m.reloadAfterBusy = false
			return m.startLogin()
		}
		if m.reloadAfterBusy {
			m.beginPagePrefetch(nil)
			m.reloadAfterBusy = false
			m.busy = true
			m.status = "正在加载来源：" + m.selectedSourceLabel()
			if m.query != "" {
				return m, m.searchCmd(m.query)
			}
			return m, m.feedCmd()
		}
		var commands []tea.Cmd
		if msg.err == nil {
			commands = m.beginPagePrefetch(m.items)
		} else {
			m.beginPagePrefetch(nil)
		}
		m.updatePrefetchStatus()
		return m, tea.Batch(commands...)
	case detailMsg:
		m.busy = false
		if msg.err != nil {
			m.status = msg.err.Error()
			if msg.prefetched && msg.generation == m.prefetchGeneration {
				m.detailPrefetchDone++
				m.detailPrefetchFailed++
				commands := m.startDetailPrefetches()
				return m, tea.Batch(commands...)
			}
			return m, nil
		}
		item := msg.item
		if item.Ref.ID == "" {
			item, _ = m.currentItem()
		}
		m.detailCache[refCacheKey(item.Ref)] = msg.detail
		if msg.prefetched && msg.generation == m.prefetchGeneration {
			m.detailPrefetchDone++
			m.enqueueDetailMedia(msg.detail)
		}
		commands := m.openDetail(msg.detail, item)
		commands = append(commands, m.startDetailPrefetches()...)
		commands = append(commands, m.startMediaPrefetches()...)
		return m, tea.Batch(commands...)
	case prefetchDetailMsg:
		if msg.generation != m.prefetchGeneration {
			return m, nil
		}
		m.detailPrefetchActive = max(0, m.detailPrefetchActive-1)
		key := refCacheKey(msg.item.Ref)
		delete(m.detailPrefetching, key)
		m.detailPrefetchDone++
		var commands []tea.Cmd
		if msg.err != nil {
			m.detailPrefetchFailed++
		} else {
			m.detailCache[key] = msg.detail
			m.enqueueDetailMedia(msg.detail)
			commands = append(commands, m.startMediaPrefetches()...)
		}
		commands = append(commands, m.startDetailPrefetches()...)
		m.updatePrefetchStatus()
		return m, tea.Batch(commands...)
	case prefetchMediaMsg:
		if msg.task.generation != m.prefetchGeneration {
			return m, nil
		}
		m.mediaPrefetchActive = max(0, m.mediaPrefetchActive-1)
		m.mediaPrefetchDone++
		if msg.err != nil {
			m.mediaPrefetchFailed++
		}
		commands := m.startMediaPrefetches()
		if m.mode == detailView && m.detail != nil && refCacheKey(m.detail.Ref) == refCacheKey(msg.task.ref) {
			m.syncDetail()
		}
		m.updatePrefetchStatus()
		return m, tea.Batch(commands...)
	case mediaLoadedMsg:
		if m.mode != detailView || m.detail == nil || msg.ref.Source != m.detail.Ref.Source || msg.ref.ID != m.detail.Ref.ID {
			return m, nil
		}
		preview := mediaPreview{image: msg.image}
		if msg.err != nil {
			preview.error = msg.err.Error()
			m.mediaFailed++
		}
		m.mediaPreviews[msg.url] = preview
		m.mediaLoading = max(0, m.mediaLoading-1)
		if m.mediaLoading == 0 {
			if m.mediaFailed > 0 {
				m.status = fmt.Sprintf("详情已载入，%d 项媒体预览失败", m.mediaFailed)
			} else {
				m.status = "详情和媒体已载入"
			}
		} else {
			m.status = fmt.Sprintf("正在加载媒体，剩余 %d 项…", m.mediaLoading)
		}
		m.syncDetail()
		return m, nil
	case actionMsg:
		m.busy = false
		m.pending = nil
		if msg.err != nil {
			m.status = "操作失败: " + msg.err.Error()
			return m, nil
		}
		m.applyAction(msg.action)
		m.status = actionSuccess(msg.action)
		m.syncDetail()
		return m, nil
	case loginQRMsg:
		m.busy = false
		if msg.err != nil {
			m.status = "获取登录二维码失败: " + msg.err.Error()
			return m, nil
		}
		if msg.challenge.LoggedIn {
			m.mode = listView
			m.status = m.loginSource.Label() + "已经登录"
			return m, nil
		}
		if _, err := renderQRCode(msg.challenge.Image, max(21, m.width-8)); err != nil {
			m.status = "二维码无法显示: " + err.Error()
			return m, nil
		}
		m.loginImage = msg.challenge.Image
		m.loginExpiresAt = time.Now().Add(msg.challenge.Timeout)
		m.mode = loginView
		m.status = "请使用" + loginAppName(m.loginSource) + "扫描二维码"
		return m, pollLoginCmd()
	case loginPollMsg:
		if m.mode != loginView {
			return m, nil
		}
		if !m.loginExpiresAt.IsZero() && time.Now().After(m.loginExpiresAt) {
			m.status = "二维码已过期，按 L 刷新"
			return m, nil
		}
		return m, m.loginStatusCmd()
	case loginStatusMsg:
		if m.mode != loginView {
			return m, nil
		}
		if msg.err != nil {
			m.status = "等待扫码: " + msg.err.Error()
			return m, pollLoginCmd()
		}
		if msg.status.LoggedIn {
			m.mode = listView
			m.loginImage = nil
			m.loginExpiresAt = time.Time{}
			m.status = m.loginSource.Label() + "登录成功"
			if msg.status.Username != "" {
				m.status += ": " + msg.status.Username
			}
			m.busy = true
			m.beginPagePrefetch(nil)
			return m, m.feedCmd()
		}
		m.status = "等待扫码确认…"
		return m, pollLoginCmd()
	case credentialLoginMsg:
		m.busy = false
		if msg.err != nil {
			m.status = "贴吧登录失败: " + msg.err.Error()
			return m, nil
		}
		m.status = "贴吧登录成功"
		if msg.status.Username != "" {
			m.status += ": " + msg.status.Username
		}
		m.beginPagePrefetch(nil)
		return m, m.feedCmd()
	case tea.KeyMsg:
		if m.pending != nil {
			switch msg.String() {
			case "y", "Y":
				action := *m.pending
				m.busy = true
				m.status = "正在执行…"
				return m, m.actionCmd(action)
			case "n", "N", "esc":
				m.pending = nil
				m.status = "已取消"
			}
			return m, nil
		}
		if m.inputMode != inputNone {
			return m.updateInput(msg)
		}
		return m.updateKeys(msg)
	}

	if m.mode == detailView && m.viewportReady {
		var command tea.Cmd
		m.viewport, command = m.viewport.Update(message)
		return m, command
	}
	return m, nil
}

func (m Model) updateInput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.stopInput()
		m.status = "输入已取消"
		return m, nil
	case "enter":
		value := strings.TrimSpace(m.input.Value())
		if value == "" {
			return m, nil
		}
		mode := m.inputMode
		m.stopInput()
		switch mode {
		case inputSearch:
			m.query = value
			m.mode = listView
			m.busy = true
			m.status = "正在搜索…"
			m.beginPagePrefetch(nil)
			return m, m.searchCmd(value)
		case inputComment:
			action := pendingAction{kind: actionComment, ref: m.currentRef(), body: value}
			m.askConfirmation(action)
			return m, nil
		case inputReply:
			comment, ok := m.currentComment()
			if !ok {
				m.status = "当前没有可回复的评论"
				return m, nil
			}
			action := pendingAction{kind: actionReply, ref: m.currentRef(), comment: comment.Ref, body: value}
			m.askConfirmation(action)
			return m, nil
		case inputTiebaCredential:
			m.busy = true
			m.status = "正在校验贴吧 BDUSS…"
			return m, m.credentialLoginCmd(value)
		}
	}
	var command tea.Cmd
	m.input, command = m.input.Update(msg)
	return m, command
}

func (m Model) updateKeys(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()
	if key == "ctrl+c" || key == "q" {
		return m, tea.Quit
	}
	if m.busy {
		if m.mode == listView {
			switch key {
			case "tab":
				m.filterIndex = (m.filterIndex + 1) % len(m.filters)
				m.reloadAfterBusy = true
				m.status = "已选择来源：" + m.selectedSourceLabel() + "；当前请求结束后自动切换"
			case "shift+tab":
				m.filterIndex = (m.filterIndex - 1 + len(m.filters)) % len(m.filters)
				m.reloadAfterBusy = true
				m.status = "已选择来源：" + m.selectedSourceLabel() + "；当前请求结束后自动切换"
			case "L":
				m.loginAfterBusy = true
				m.reloadAfterBusy = false
				m.status = "当前请求结束后获取" + m.loginTarget().Label() + "登录二维码"
			}
		}
		return m, nil
	}
	if m.mode == loginView {
		switch key {
		case "esc", "b", "backspace":
			m.mode = listView
			m.status = "已关闭登录页"
			return m, nil
		case "L", "r":
			m.busy = true
			m.status = "正在刷新登录二维码…"
			return m, m.loginQRCmd(m.loginSource)
		}
		return m, nil
	}

	if m.mode == detailView {
		switch key {
		case "esc", "b", "backspace":
			m.mode = listView
			m.status = "返回信息流"
			m.updatePrefetchStatus()
			return m, nil
		case "j", "down":
			m.viewport.LineDown(1)
			return m, nil
		case "k", "up":
			m.viewport.LineUp(1)
			return m, nil
		case "J":
			if m.detail != nil && len(m.detail.Comments) > 0 {
				m.commentSelected = min(m.commentSelected+1, len(m.detail.Comments)-1)
				m.syncDetail()
			}
			return m, nil
		case "K":
			m.commentSelected = max(0, m.commentSelected-1)
			m.syncDetail()
			return m, nil
		case "R":
			if _, ok := m.currentComment(); ok {
				return m.startInput(inputReply), textinput.Blink
			}
			m.status = "当前没有可回复的评论"
			return m, nil
		}
	}

	switch key {
	case "L":
		return m.startLogin()
	case "B":
		return m.startTiebaCredential()
	case "1", "2", "3":
		index := int(key[0] - '1')
		if index < len(m.channels) {
			m.channelIndex = index
			m.query = ""
			m.mode = listView
			m.selected = 0
			m.busy = true
			m.status = "正在切换到" + m.currentChannel().Label() + "…"
			m.beginPagePrefetch(nil)
			return m, m.feedCmd()
		}
	case "/":
		return m.startInput(inputSearch), textinput.Blink
	case "tab":
		m.filterIndex = (m.filterIndex + 1) % len(m.filters)
		m.busy = true
		m.status = "正在切换到来源：" + m.selectedSourceLabel()
		m.beginPagePrefetch(nil)
		if m.query != "" {
			return m, m.searchCmd(m.query)
		}
		return m, m.feedCmd()
	case "shift+tab":
		m.filterIndex = (m.filterIndex - 1 + len(m.filters)) % len(m.filters)
		m.busy = true
		m.status = "正在切换到来源：" + m.selectedSourceLabel()
		m.beginPagePrefetch(nil)
		if m.query != "" {
			return m, m.searchCmd(m.query)
		}
		return m, m.feedCmd()
	case "r":
		m.busy = true
		m.status = "正在刷新…"
		m.beginPagePrefetch(nil)
		if m.query != "" {
			return m, m.searchCmd(m.query)
		}
		return m, m.feedCmd()
	case "j", "down":
		m.selected = min(m.selected+1, max(0, len(m.items)-1))
	case "k", "up":
		m.selected = max(0, m.selected-1)
	case "g", "home":
		m.selected = 0
	case "G", "end":
		m.selected = max(0, len(m.items)-1)
	case "enter":
		if item, ok := m.currentItem(); ok {
			key := refCacheKey(item.Ref)
			if detail, cached := m.detailCache[key]; cached {
				commands := m.openDetail(detail, item)
				if len(commands) == 0 {
					m.status = "已从缓存打开详情和媒体"
				}
				return m, tea.Batch(commands...)
			}
			m.busy = true
			if m.detailPrefetching[key] {
				m.status = "正在打开后台缓存中的详情…"
				return m, m.detailCmd(item, false)
			}
			prefetched := m.removeQueuedDetail(key)
			m.status = "正在读取详情…"
			commands := []tea.Cmd{m.detailCmd(item, prefetched)}
			commands = append(commands, m.startDetailPrefetches()...)
			return m, tea.Batch(commands...)
		}
	case "l":
		if item, ok := m.currentItem(); ok {
			m.askConfirmation(pendingAction{kind: actionLike, ref: item.Ref, value: !item.Liked})
		}
	case "f":
		if item, ok := m.currentItem(); ok {
			m.askConfirmation(pendingAction{kind: actionFavorite, ref: item.Ref, value: !item.Favorited})
		}
	case "c":
		if _, ok := m.currentItem(); ok {
			return m.startInput(inputComment), textinput.Blink
		}
	}
	return m, nil
}

func (m Model) View() string {
	width := max(40, m.width)
	header := lipgloss.NewStyle().Bold(true).Foreground(accent).Render("mixsocial")
	channels := make([]string, 0, len(m.channels))
	for index, channel := range m.channels {
		style := lipgloss.NewStyle().Foreground(mutedColor)
		if index == m.channelIndex && m.query == "" {
			style = style.Foreground(accent).Bold(true).Underline(true)
		}
		channels = append(channels, style.Render(fmt.Sprintf("%d %s", index+1, channel.Label())))
	}
	filters := make([]string, 0, len(m.filters))
	for index, id := range m.filters {
		label := "全部"
		if id != "" {
			label = id.Label()
		}
		style := lipgloss.NewStyle().Foreground(mutedColor)
		if index == m.filterIndex {
			style = style.Foreground(accent).Bold(true).Underline(true)
		}
		filters = append(filters, style.Render(label))
	}
	top := header + "  " + strings.Join(channels, "  ") + "    来源 " + strings.Join(filters, "  ")
	top = lipgloss.NewStyle().Width(width).Padding(0, 1).Render(top)
	if m.mode == detailView {
		top = m.kittyImagePreamble() + top
	}

	var content string
	if m.mode == loginView {
		content = m.renderLogin()
	} else if m.mode == detailView {
		if m.viewportReady {
			content = m.viewport.View()
		}
	} else {
		content = m.renderList()
	}

	statusStyle := lipgloss.NewStyle().Foreground(mutedColor)
	if strings.Contains(m.status, "失败") || strings.Contains(m.status, "不可用") || strings.Contains(m.status, "HTTP") {
		statusStyle = statusStyle.Foreground(errorColor)
	}
	status := statusStyle.Render(singleLine(m.status, max(20, width-4)))
	if m.pending != nil {
		status = lipgloss.NewStyle().Foreground(accent).Bold(true).Render(confirmText(*m.pending) + "  [y/N]")
	}
	if m.inputMode != inputNone {
		status = m.input.View()
	}
	help := m.listHelp()
	if m.mode == detailView {
		help = "j/k 滚动  J/K 选评论  R 回复  b 返回  L 登录  l 点赞  f 收藏  c 评论  q 退出"
	} else if m.mode == loginView {
		help = "使用" + loginAppName(m.loginSource) + "扫码  L/r 刷新二维码  b/esc 返回  q 退出"
	}
	help = singleLine("图片 "+m.imageConfig.statusLabel()+"  ·  "+help, max(20, width-4))
	footer := lipgloss.NewStyle().BorderTop(true).BorderForeground(borderColor).Width(max(20, width-2)).Padding(0, 1).Render(status + "\n" + lipgloss.NewStyle().Foreground(mutedColor).Render(help))
	return top + "\n" + content + "\n" + footer
}

func (m Model) renderList() string {
	width := max(36, m.width-4)
	available := max(4, m.height-7)
	if len(m.items) == 0 {
		message := "暂无内容。按 / 搜索；贴吧搜索词按吧名解释。"
		if len(m.notices) > 0 {
			message += "\n\n" + strings.Join(m.notices, "\n")
		}
		return lipgloss.NewStyle().Width(width).Height(available).Padding(1, 2).Foreground(mutedColor).Render(message)
	}
	// Each topic uses two content lines plus a blank separator. Keeping the
	// separator in the row budget prevents dense lists from visually merging.
	rows := max(1, available/4)
	start := 0
	if m.selected >= rows {
		start = m.selected - rows + 1
	}
	end := min(len(m.items), start+rows)
	var blocks []string
	for index := start; index < end; index++ {
		item := m.items[index]
		marker := "  "
		style := lipgloss.NewStyle().Width(width).Padding(0, 1)
		if index == m.selected {
			marker = "› "
			style = style.BorderLeft(true).BorderForeground(accent)
		}
		title := item.Title
		if title == "" {
			title = firstLine(item.Summary)
		}
		meta := sourceBadge(item.Ref.Source) + "  " + fallback(item.Author.Name, "匿名") + "  " + formatTime(item.PublishedAt)
		stats := formatStats(item)
		if stats != "" {
			meta += "  " + stats
		}
		if media := mediaSummary(item.Media); media != "" {
			meta += "  " + media
		}
		block := marker + truncate(title, max(12, width-6)) + "\n" + "  " + meta
		blocks = append(blocks, style.Render(block))
	}
	if len(m.notices) > 0 && start == 0 {
		blocks = append([]string{lipgloss.NewStyle().Foreground(mutedColor).Render("提示: " + singleLine(strings.Join(m.notices, " · "), width))}, blocks...)
	}
	return lipgloss.NewStyle().Width(width).Height(available).Padding(0, 1).Render(strings.Join(blocks, "\n\n"))
}

func (m Model) renderLogin() string {
	width := max(36, m.width-4)
	height := max(6, m.height-6)
	if len(m.loginImage) == 0 {
		return lipgloss.NewStyle().Width(width).Height(height).Padding(1, 2).Foreground(mutedColor).Render("登录二维码尚未载入，按 L 获取。")
	}
	qr, err := renderQRCode(m.loginImage, min(75, max(21, width-4)), max(1, height-2))
	if err != nil {
		return lipgloss.NewStyle().Width(width).Height(height).Padding(1, 2).Foreground(errorColor).Render("二维码无法显示: " + err.Error())
	}
	color := xhsColor
	if m.loginSource == domain.SourceTieba {
		color = tiebaColor
	}
	title := lipgloss.NewStyle().Bold(true).Foreground(color).Render(m.loginSource.Label() + "扫码登录")
	remaining := time.Until(m.loginExpiresAt).Round(time.Second)
	if remaining < 0 {
		remaining = 0
	}
	instructions := lipgloss.NewStyle().Foreground(mutedColor).Render("使用" + loginAppName(m.loginSource) + "扫描 · 剩余 " + remaining.String())
	if usesBraille(qr) {
		instructions += lipgloss.NewStyle().Foreground(mutedColor).Render(" · 紧凑模式；放大终端可切换标准模式")
	}
	return title + "\n" + centerBlock(qr, width) + "\n" + instructions
}

func usesBraille(value string) bool {
	for _, char := range value {
		if char >= '\u2800' && char <= '\u28ff' {
			return true
		}
	}
	return false
}

func (m *Model) resize(width, height int) {
	m.width, m.height = width, height
	m.input.Width = max(16, width-14)
	viewportWidth := max(30, width-4)
	viewportHeight := max(4, height-6)
	if !m.viewportReady {
		m.viewport = viewport.New(viewportWidth, viewportHeight)
		m.viewport.MouseWheelEnabled = true
		m.viewportReady = true
	} else {
		m.viewport.Width = viewportWidth
		m.viewport.Height = viewportHeight
	}
	m.syncDetail()
}

func (m *Model) openDetail(detail domain.Detail, item domain.Item) []tea.Cmd {
	m.detailCache[refCacheKey(item.Ref)] = detail
	m.detail = &detail
	m.mode = detailView
	m.commentSelected = 0
	m.mediaPreviews = make(map[string]mediaPreview)
	m.viewport.SetYOffset(0)
	commands := m.prepareMediaLoads()
	m.mediaLoading = len(commands)
	m.mediaFailed = 0
	m.status = "详情已载入"
	if m.mediaLoading > 0 {
		m.status = fmt.Sprintf("详情已载入，正在加载 %d 项媒体…", m.mediaLoading)
	} else if len(detail.Media) > 0 {
		m.status = "详情和媒体已从缓存载入"
	}
	m.syncDetail()
	return commands
}

func (m *Model) syncDetail() {
	if !m.viewportReady || m.detail == nil {
		return
	}
	detail := m.detail
	width := max(24, m.viewport.Width-4)
	var blocks []string
	blocks = append(blocks, lipgloss.NewStyle().Bold(true).Foreground(textColor).Width(width).Render(detail.Title))
	meta := sourceBadge(detail.Ref.Source) + "  " + fallback(detail.Author.Name, "匿名") + "  " + formatTime(detail.PublishedAt) + "  " + formatStats(detail.Item)
	blocks = append(blocks, lipgloss.NewStyle().Foreground(mutedColor).Render(meta))
	if detail.Body != "" {
		blocks = append(blocks, lipgloss.NewStyle().Foreground(textColor).Width(width).Render(detail.Body))
	}
	if len(detail.Media) > 0 {
		blocks = append(blocks, lipgloss.NewStyle().Bold(true).Render(fmt.Sprintf("媒体 %d 项", len(detail.Media))))
		for index, media := range detail.Media {
			blocks = append(blocks, m.renderMedia(media, index, width))
		}
	}
	if detail.Ref.URL != "" {
		blocks = append(blocks, lipgloss.NewStyle().Foreground(mutedColor).Render("原文: "+detail.Ref.URL))
	}
	blocks = append(blocks, lipgloss.NewStyle().Bold(true).Render(fmt.Sprintf("评论 %d", len(detail.Comments))))
	for index, comment := range detail.Comments {
		marker := "  "
		style := lipgloss.NewStyle().Width(width).PaddingLeft(1)
		if index == m.commentSelected {
			marker = "› "
			style = style.BorderLeft(true).BorderForeground(accent)
		}
		line := marker + fallback(comment.Author.Name, "匿名") + " · " + formatTime(comment.PublishedAt) + "\n  " + comment.Body
		if len(comment.Replies) > 0 {
			line += fmt.Sprintf("\n  ↳ %d 条回复", len(comment.Replies))
		}
		for mediaIndex, media := range comment.Media {
			line += "\n" + m.renderMedia(media, mediaIndex, max(20, width-3))
		}
		blocks = append(blocks, style.Render(line))
	}
	y := m.viewport.YOffset
	m.viewport.SetContent(strings.Join(blocks, "\n\n"))
	m.viewport.SetYOffset(y)
}

func (m Model) feedCmd() tea.Cmd {
	filter := m.filters[m.filterIndex]
	channel := m.currentChannel()
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
		defer cancel()
		page, err := m.mixed.Browse(ctx, filter, channel, "")
		return pageMsg{page: page, err: err}
	}
}

func (m Model) searchCmd(query string) tea.Cmd {
	filter := m.filters[m.filterIndex]
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
		defer cancel()
		page, err := m.mixed.Search(ctx, filter, query, "")
		return pageMsg{page: page, err: err, query: query}
	}
}

func (m Model) detailCmd(item domain.Item, prefetched bool) tea.Cmd {
	generation := m.prefetchGeneration
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
		return detailMsg{detail: detail, item: item, generation: generation, prefetched: prefetched, err: err}
	}
}

func (m Model) actionCmd(action pendingAction) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
		defer cancel()
		interactor, ok := m.mixed.Interactor(action.ref.Source)
		if !ok {
			return actionMsg{action: action, err: fmt.Errorf("%s 不支持此操作", action.ref.Source.Label())}
		}
		var err error
		switch action.kind {
		case actionLike:
			err = interactor.Like(ctx, action.ref, action.value)
		case actionFavorite:
			err = interactor.Favorite(ctx, action.ref, action.value)
		case actionComment:
			err = interactor.Comment(ctx, action.ref, action.body)
		case actionReply:
			err = interactor.Reply(ctx, action.ref, action.comment, action.body)
		}
		return actionMsg{action: action, err: err}
	}
}

func (m Model) loginQRCmd(id domain.SourceID) tea.Cmd {
	return func() tea.Msg {
		authenticator, ok := m.mixed.Authenticator(id)
		if !ok {
			return loginQRMsg{err: fmt.Errorf("%s数据源不支持扫码登录", id.Label())}
		}
		ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
		defer cancel()
		challenge, err := authenticator.LoginQRCode(ctx)
		return loginQRMsg{challenge: challenge, err: err}
	}
}

func (m Model) loginStatusCmd() tea.Cmd {
	id := m.loginSource
	return func() tea.Msg {
		authenticator, ok := m.mixed.Authenticator(id)
		if !ok {
			return loginStatusMsg{err: fmt.Errorf("%s数据源不支持登录状态检查", id.Label())}
		}
		ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
		defer cancel()
		status, err := authenticator.LoginStatus(ctx)
		return loginStatusMsg{status: status, err: err}
	}
}

func (m Model) credentialLoginCmd(credential string) tea.Cmd {
	return func() tea.Msg {
		authenticator, ok := m.mixed.CredentialAuthenticator(domain.SourceTieba)
		if !ok {
			return credentialLoginMsg{err: fmt.Errorf("贴吧数据源不支持 BDUSS 登录")}
		}
		ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
		defer cancel()
		status, err := authenticator.LoginWithCredential(ctx, credential)
		return credentialLoginMsg{status: status, err: err}
	}
}

func pollLoginCmd() tea.Cmd {
	return tea.Tick(3*time.Second, func(time.Time) tea.Msg { return loginPollMsg{} })
}

func (m Model) startInput(mode inputMode) Model {
	m.inputMode = mode
	m.input.SetValue("")
	m.input.EchoMode = textinput.EchoNormal
	m.input.CharLimit = 120
	switch mode {
	case inputSearch:
		m.input.Prompt = "搜索 › "
		m.input.Placeholder = "贴吧吧名 / 小红书关键词"
	case inputComment:
		m.input.Prompt = "评论 › "
		m.input.Placeholder = "输入评论，回车后仍需确认"
	case inputReply:
		m.input.Prompt = "回复 › "
		m.input.Placeholder = "回复选中评论，回车后仍需确认"
	case inputTiebaCredential:
		m.input.Prompt = "贴吧 BDUSS › "
		m.input.Placeholder = "粘贴 BDUSS 或 BDUSS=...; STOKEN=..."
		m.input.EchoMode = textinput.EchoPassword
		m.input.EchoCharacter = '•'
		m.input.CharLimit = 1024
	}
	m.input.Focus()
	return m
}

func (m Model) startLogin() (tea.Model, tea.Cmd) {
	target := m.loginTarget()
	if _, ok := m.mixed.Authenticator(target); ok {
		m.loginSource = target
		m.busy = true
		m.status = "正在获取" + target.Label() + "登录二维码…"
		return m, m.loginQRCmd(target)
	}
	if target == domain.SourceTieba {
		return m.startTiebaCredential()
	}
	m.status = "请先用 Tab 选择贴吧或小红书来源，再按 L 登录"
	return m, nil
}

func (m Model) startTiebaCredential() (tea.Model, tea.Cmd) {
	if _, ok := m.mixed.CredentialAuthenticator(domain.SourceTieba); !ok {
		m.status = "贴吧数据源不支持 BDUSS 登录"
		return m, nil
	}
	if target := m.loginTarget(); target != "" && target != domain.SourceTieba {
		m.status = "请先用 Tab 切到贴吧来源，再按 B 导入 BDUSS"
		return m, nil
	}
	m.status = "请粘贴 tieba.baidu.com Cookie 中的 BDUSS；输入会被遮罩"
	return m.startInput(inputTiebaCredential), textinput.Blink
}

func loginAppName(id domain.SourceID) string {
	if id == domain.SourceTieba {
		return "百度 App"
	}
	return "小红书 App"
}

func (m Model) loginTarget() domain.SourceID {
	filter := m.filters[m.filterIndex]
	if filter != "" {
		return filter
	}
	if item, ok := m.currentItem(); ok {
		return item.Ref.Source
	}
	return ""
}

func (m Model) selectedSourceLabel() string {
	if m.filterIndex < 0 || m.filterIndex >= len(m.filters) || m.filters[m.filterIndex] == "" {
		return "全部"
	}
	return m.filters[m.filterIndex].Label()
}

func (m Model) listHelp() string {
	help := "1/2/3 推荐/热榜/关注  tab 来源  j/k 移动  / 搜索"
	switch m.loginTarget() {
	case domain.SourceTieba:
		help += "  L 贴吧扫码  B 导入BDUSS"
	case domain.SourceXHS:
		help += "  L 小红书扫码"
	default:
		help += "  L 登录"
	}
	return help + "  q 退出"
}

func (m Model) currentChannel() source.Channel {
	if m.channelIndex < 0 || m.channelIndex >= len(m.channels) {
		return source.ChannelRecommend
	}
	return m.channels[m.channelIndex]
}

func (m *Model) stopInput() {
	m.input.Blur()
	m.input.SetValue("")
	m.inputMode = inputNone
}

func (m *Model) askConfirmation(action pendingAction) {
	if _, ok := m.mixed.Interactor(action.ref.Source); !ok {
		m.status = action.ref.Source.Label() + " 当前仅支持读取"
		return
	}
	m.pending = &action
	m.status = confirmText(action)
}

func (m *Model) applyAction(action pendingAction) {
	for index := range m.items {
		if m.items[index].Ref.Source == action.ref.Source && m.items[index].Ref.ID == action.ref.ID {
			if action.kind == actionLike {
				m.items[index].Liked = action.value
			}
			if action.kind == actionFavorite {
				m.items[index].Favorited = action.value
			}
		}
	}
	if m.detail != nil && m.detail.Ref.Source == action.ref.Source && m.detail.Ref.ID == action.ref.ID {
		if action.kind == actionLike {
			m.detail.Liked = action.value
		}
		if action.kind == actionFavorite {
			m.detail.Favorited = action.value
		}
	}
	for key, detail := range m.detailCache {
		if detail.Ref.Source != action.ref.Source || detail.Ref.ID != action.ref.ID {
			continue
		}
		if action.kind == actionLike {
			detail.Liked = action.value
		}
		if action.kind == actionFavorite {
			detail.Favorited = action.value
		}
		m.detailCache[key] = detail
	}
}

func (m Model) currentItem() (domain.Item, bool) {
	if m.mode == detailView && m.detail != nil {
		return m.detail.Item, true
	}
	if m.selected >= 0 && m.selected < len(m.items) {
		return m.items[m.selected], true
	}
	return domain.Item{}, false
}

func (m Model) currentRef() domain.Ref {
	item, _ := m.currentItem()
	return item.Ref
}

func (m Model) currentComment() (domain.Comment, bool) {
	if m.detail == nil || m.commentSelected < 0 || m.commentSelected >= len(m.detail.Comments) {
		return domain.Comment{}, false
	}
	return m.detail.Comments[m.commentSelected], true
}

func sourceBadge(id domain.SourceID) string {
	color := accent
	if id == domain.SourceTieba {
		color = tiebaColor
	} else if id == domain.SourceXHS {
		color = xhsColor
	}
	return lipgloss.NewStyle().Foreground(color).Bold(true).Render("[" + id.Label() + "]")
}

func formatStats(item domain.Item) string {
	var fields []string
	if item.Stats.Views > 0 {
		fields = append(fields, "阅 "+compactNumber(item.Stats.Views))
	}
	if item.Stats.Likes > 0 || item.Liked {
		prefix := "赞 "
		if item.Liked {
			prefix = "♥ "
		}
		fields = append(fields, prefix+compactNumber(item.Stats.Likes))
	}
	if item.Stats.Comments > 0 {
		fields = append(fields, "评 "+compactNumber(item.Stats.Comments))
	}
	if item.Stats.Favorites > 0 || item.Favorited {
		prefix := "藏 "
		if item.Favorited {
			prefix = "★ "
		}
		fields = append(fields, prefix+compactNumber(item.Stats.Favorites))
	}
	return strings.Join(fields, "  ")
}

func compactNumber(value int64) string {
	if value >= 10000 {
		return strconv.FormatFloat(float64(value)/10000, 'f', 1, 64) + "万"
	}
	return strconv.FormatInt(value, 10)
}

func formatTime(value time.Time) string {
	if value.IsZero() {
		return "时间未知"
	}
	delta := time.Since(value)
	if delta >= 0 && delta < time.Hour {
		return fmt.Sprintf("%d 分钟前", max(1, int(delta.Minutes())))
	}
	if delta >= 0 && delta < 24*time.Hour {
		return fmt.Sprintf("%d 小时前", max(1, int(delta.Hours())))
	}
	return value.Format("01-02 15:04")
}

func confirmText(action pendingAction) string {
	switch action.kind {
	case actionLike:
		if action.value {
			return "确认点赞？"
		}
		return "确认取消点赞？"
	case actionFavorite:
		if action.value {
			return "确认收藏？"
		}
		return "确认取消收藏？"
	case actionComment:
		return "确认发送评论“" + truncate(action.body, 30) + "”？"
	case actionReply:
		return "确认发送回复“" + truncate(action.body, 30) + "”？"
	default:
		return "确认操作？"
	}
}

func actionSuccess(action pendingAction) string {
	switch action.kind {
	case actionLike:
		if action.value {
			return "点赞成功"
		}
		return "已取消点赞"
	case actionFavorite:
		if action.value {
			return "收藏成功"
		}
		return "已取消收藏"
	case actionComment:
		return "评论已发送"
	case actionReply:
		return "回复已发送"
	default:
		return "操作成功"
	}
}

func renderQRCode(encoded []byte, maxWidth int, maxRows ...int) (string, error) {
	img, _, err := image.Decode(bytes.NewReader(encoded))
	if err != nil {
		return "", fmt.Errorf("解码图片: %w", err)
	}
	// Sidecars commonly return a 128px QR image without a quiet zone. Scaling
	// that raster to an arbitrary terminal width breaks module boundaries and
	// makes phone scanners unreliable. Decode the payload and regenerate the
	// exact module bitmap (including its four-module quiet zone) first.
	if payload := recognizeQRPayload(img); len(payload) > 0 {
		// A terminal rendering has perfect contrast but limited space. Low error
		// correction produces the smallest exact grid and is more reliable than
		// clipping a larger QR at the bottom of a normal terminal window.
		qr, encodeErr := qrcode.New(string(payload), qrcode.Low)
		if encodeErr == nil {
			bitmap := qr.Bitmap()
			return renderQRBitmap(bitmap, maxWidth, maxRows...)
		}
	}
	return renderRasterQRCode(withWhiteBorder(img), maxWidth)
}

func recognizeQRPayload(img image.Image) []byte {
	for _, candidate := range []image.Image{img, withWhiteBorder(img)} {
		decoded, err := goqr.Recognize(candidate)
		if err == nil && len(decoded) > 0 && len(decoded[0].Payload) > 0 {
			return decoded[0].Payload
		}
		bitmap, bitmapErr := gozxing.NewBinaryBitmapFromImage(candidate)
		if bitmapErr != nil {
			continue
		}
		result, decodeErr := zxingqrcode.NewQRCodeReader().Decode(bitmap, nil)
		if decodeErr == nil && result != nil && result.GetText() != "" {
			return []byte(result.GetText())
		}
	}
	return nil
}

func withWhiteBorder(img image.Image) image.Image {
	bounds := img.Bounds()
	padding := max(8, max(bounds.Dx(), bounds.Dy())/12)
	padded := image.NewNRGBA(image.Rect(0, 0, bounds.Dx()+2*padding, bounds.Dy()+2*padding))
	draw.Draw(padded, padded.Bounds(), &image.Uniform{C: color.White}, image.Point{}, draw.Src)
	draw.Draw(padded, image.Rect(padding, padding, padding+bounds.Dx(), padding+bounds.Dy()), img, bounds.Min, draw.Src)
	return padded
}

func renderQRBitmap(bitmap [][]bool, maxWidth int, maxRows ...int) (string, error) {
	if len(bitmap) < 21 {
		return "", fmt.Errorf("二维码网格尺寸无效")
	}
	rowLimit := int(^uint(0) >> 1)
	if len(maxRows) > 0 {
		rowLimit = maxRows[0]
	}
	if (len(bitmap)+1)/2 > rowLimit {
		if (len(bitmap)+3)/4 <= rowLimit && (len(bitmap)+1)/2 <= maxWidth {
			return renderQRBraille(bitmap), nil
		}
		return "", fmt.Errorf("终端高度不足，需要至少 %d 行；请放大窗口", (len(bitmap)+3)/4+2)
	}
	if len(bitmap) > maxWidth {
		return "", fmt.Errorf("终端宽度不足，需要至少 %d 列", len(bitmap))
	}
	width := len(bitmap[0])
	if width != len(bitmap) {
		return "", fmt.Errorf("二维码网格尺寸无效")
	}
	isDark := func(x, y int) bool {
		return y >= 0 && y < len(bitmap) && x >= 0 && x < len(bitmap[y]) && bitmap[y][x]
	}
	return renderQRCells(width, len(bitmap), isDark), nil
}

func renderQRBraille(bitmap [][]bool) string {
	var output strings.Builder
	for y := 0; y < len(bitmap); y += 4 {
		output.WriteString("\x1b[30;47m")
		for x := 0; x < len(bitmap); x += 2 {
			var dots rune
			for dy := 0; dy < 4; dy++ {
				for dx := 0; dx < 2; dx++ {
					if y+dy >= len(bitmap) || x+dx >= len(bitmap[y+dy]) || !bitmap[y+dy][x+dx] {
						continue
					}
					bits := [4][2]rune{{1, 8}, {2, 16}, {4, 32}, {64, 128}}
					dots |= bits[dy][dx]
				}
			}
			if dots == 0 {
				output.WriteByte(' ')
			} else {
				output.WriteRune('\u2800' + dots)
			}
		}
		output.WriteString("\x1b[0m")
		if y+4 < len(bitmap) {
			output.WriteByte('\n')
		}
	}
	return output.String()
}

func renderRasterQRCode(img image.Image, maxWidth int) (string, error) {
	bounds := img.Bounds()
	if bounds.Dx() < 1 || bounds.Dy() < 1 {
		return "", fmt.Errorf("二维码尺寸无效")
	}
	targetWidth := min(bounds.Dx(), maxWidth)
	if targetWidth < 21 {
		return "", fmt.Errorf("终端宽度不足")
	}
	targetHeight := max(1, bounds.Dy()*targetWidth/bounds.Dx())

	isDark := func(targetX, targetY int) bool {
		if targetY >= targetHeight {
			return false
		}
		x0 := bounds.Min.X + targetX*bounds.Dx()/targetWidth
		x1 := bounds.Min.X + (targetX+1)*bounds.Dx()/targetWidth
		y0 := bounds.Min.Y + targetY*bounds.Dy()/targetHeight
		y1 := bounds.Min.Y + (targetY+1)*bounds.Dy()/targetHeight
		if x1 <= x0 {
			x1 = x0 + 1
		}
		if y1 <= y0 {
			y1 = y0 + 1
		}
		var luminance uint64
		var count uint64
		for y := y0; y < y1 && y < bounds.Max.Y; y++ {
			for x := x0; x < x1 && x < bounds.Max.X; x++ {
				r, g, b, a := img.At(x, y).RGBA()
				// Composite transparency over white before thresholding.
				r += 0xffff - a
				g += 0xffff - a
				b += 0xffff - a
				luminance += (299*uint64(r) + 587*uint64(g) + 114*uint64(b)) / 1000
				count++
			}
		}
		return count > 0 && luminance/count < 0x8000
	}

	return renderQRCells(targetWidth, targetHeight, isDark), nil
}

func renderQRCells(width, height int, isDark func(x, y int) bool) string {
	var output strings.Builder
	for y := 0; y < height; y += 2 {
		for x := 0; x < width; x++ {
			top, bottom := isDark(x, y), isDark(x, y+1)
			switch {
			case top && bottom:
				output.WriteString("\x1b[40m ")
			case top:
				output.WriteString("\x1b[30;47m▀")
			case bottom:
				output.WriteString("\x1b[30;47m▄")
			default:
				output.WriteString("\x1b[47m ")
			}
		}
		output.WriteString("\x1b[0m")
		if y+2 < height {
			output.WriteByte('\n')
		}
	}
	return output.String()
}

func centerBlock(block string, width int) string {
	lines := strings.Split(block, "\n")
	for index, line := range lines {
		padding := max(0, (width-lipgloss.Width(line))/2)
		lines[index] = strings.Repeat(" ", padding) + line
	}
	return strings.Join(lines, "\n")
}

func truncate(value string, limit int) string {
	value = strings.Join(strings.Fields(value), " ")
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return string(runes[:max(1, limit-1)]) + "…"
}

func singleLine(value string, limit int) string { return truncate(value, limit) }

func firstLine(value string) string {
	if index := strings.IndexByte(value, '\n'); index >= 0 {
		return value[:index]
	}
	return value
}

func fallback(value, replacement string) string {
	if strings.TrimSpace(value) == "" {
		return replacement
	}
	return value
}

func clamp(value, low, high int) int { return min(max(value, low), high) }
