package xhs

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
)

type Config struct {
	Endpoint     string
	Token        string
	Client       *http.Client
	SessionPath  string
	GuardSession bool
}

type Provider struct {
	endpoint     string
	token        string
	client       *http.Client
	sessionPath  string
	guardSession bool
	requestGate  chan struct{}

	loginMu       sync.Mutex
	loginWaiting  bool
	loginBaseline [sha256.Size]byte
	baselineSet   bool
}

func New(config Config) *Provider {
	endpoint := strings.TrimRight(strings.TrimSpace(config.Endpoint), "/")
	if endpoint == "" {
		endpoint = "http://127.0.0.1:18060"
	}
	client := config.Client
	if client == nil {
		client = &http.Client{Timeout: 45 * time.Second}
	}
	return &Provider{
		endpoint: endpoint, token: config.Token, client: client, sessionPath: config.SessionPath,
		guardSession: config.GuardSession, requestGate: make(chan struct{}, 1),
	}
}

func (*Provider) ID() domain.SourceID { return domain.SourceXHS }
func (*Provider) Name() string        { return "小红书" }
func (*Provider) Capabilities() source.Capability {
	return source.CapabilityFeed | source.CapabilitySearch | source.CapabilityDetail |
		source.CapabilityLike | source.CapabilityFavorite | source.CapabilityComment | source.CapabilityReply |
		source.CapabilityHot | source.CapabilityQRCodeLogin
}

func (p *Provider) LoginStatus(ctx context.Context) (source.LoginStatus, error) {
	if status, handled, err := p.passiveLoginStatus(); handled {
		return status, err
	}
	var payload struct {
		LoggedIn bool   `json:"is_logged_in"`
		Username string `json:"username"`
		UserID   string `json:"user_id"`
	}
	if err := p.request(ctx, http.MethodGet, "/api/v1/login/status", nil, &payload); err != nil {
		return source.LoginStatus{}, err
	}
	return source.LoginStatus{LoggedIn: payload.LoggedIn, Username: payload.Username, UserID: payload.UserID}, nil
}

func (p *Provider) LoginQRCode(ctx context.Context) (source.LoginChallenge, error) {
	var payload struct {
		LoggedIn bool   `json:"is_logged_in"`
		Image    string `json:"img"`
		Timeout  string `json:"timeout"`
	}
	if err := p.request(ctx, http.MethodGet, "/api/v1/login/qrcode", nil, &payload); err != nil {
		return source.LoginChallenge{}, err
	}
	challenge := source.LoginChallenge{LoggedIn: payload.LoggedIn, Timeout: parseDuration(payload.Timeout)}
	if challenge.LoggedIn {
		return challenge, nil
	}
	encoded := payload.Image
	if comma := strings.IndexByte(encoded, ','); comma >= 0 {
		encoded = encoded[comma+1:]
	}
	image, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return source.LoginChallenge{}, fmt.Errorf("解析登录二维码: %w", err)
	}
	if len(image) == 0 {
		return source.LoginChallenge{}, fmt.Errorf("sidecar 未返回登录二维码")
	}
	challenge.Image = image
	if challenge.Timeout <= 0 {
		challenge.Timeout = 4 * time.Minute
	}
	p.armPassiveLogin()
	return challenge, nil
}

// The sidecar deliberately keeps the QR browser alive until the scan finishes.
// Calling its normal status endpoint during that window starts another browser
// and can make Chromium instances fight over resources. The sidecar writes the
// authenticated cookies when its background waiter succeeds, so watching that
// file is both cheaper and race-free.
func (p *Provider) armPassiveLogin() {
	if p.sessionPath == "" {
		return
	}
	digest, exists, _ := sessionDigest(p.sessionPath)
	p.loginMu.Lock()
	p.loginWaiting = true
	p.loginBaseline = digest
	p.baselineSet = exists
	p.loginMu.Unlock()
	_ = protectSessionFile(p.sessionPath)
}

func (p *Provider) passiveLoginStatus() (source.LoginStatus, bool, error) {
	p.loginMu.Lock()
	defer p.loginMu.Unlock()
	if !p.loginWaiting || p.sessionPath == "" {
		return source.LoginStatus{}, false, nil
	}
	digest, exists, err := sessionDigest(p.sessionPath)
	if err != nil {
		return source.LoginStatus{}, true, fmt.Errorf("读取小红书扫码会话: %w", err)
	}
	if !exists || (p.baselineSet && digest == p.loginBaseline) {
		return source.LoginStatus{}, true, nil
	}
	hasCookies, err := sessionHasCookies(p.sessionPath)
	if err != nil {
		return source.LoginStatus{}, true, fmt.Errorf("解析小红书扫码会话: %w", err)
	}
	if !hasCookies {
		return source.LoginStatus{}, true, nil
	}
	if err := protectSessionFile(p.sessionPath); err != nil {
		return source.LoginStatus{}, true, err
	}
	p.loginWaiting = false
	return source.LoginStatus{LoggedIn: true}, true, nil
}

func sessionDigest(path string) ([sha256.Size]byte, bool, error) {
	encoded, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return [sha256.Size]byte{}, false, nil
	}
	if err != nil {
		return [sha256.Size]byte{}, false, err
	}
	return sha256.Sum256(encoded), true, nil
}

func sessionHasCookies(path string) (bool, error) {
	encoded, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	raw := json.RawMessage(encoded)
	var wrapper struct {
		Cookies json.RawMessage `json:"cookies"`
	}
	if json.Unmarshal(encoded, &wrapper) == nil && len(wrapper.Cookies) > 0 {
		raw = wrapper.Cookies
	}
	var cookies []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(raw, &cookies); err != nil {
		return false, err
	}
	return len(cookies) > 0, nil
}

func protectSessionFile(path string) error {
	if err := os.Chmod(path, 0o600); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("保护小红书会话文件: %w", err)
	}
	return nil
}

func (p *Provider) requireSavedLogin(path string) error {
	if !p.guardSession || p.sessionPath == "" || strings.HasPrefix(path, "/api/v1/login/") {
		return nil
	}
	hasCookies, err := sessionHasCookies(p.sessionPath)
	if os.IsNotExist(err) || (err == nil && !hasCookies) {
		return fmt.Errorf("小红书需要登录；切到小红书来源后按 L 扫码")
	}
	if err != nil {
		return fmt.Errorf("读取小红书会话: %w", err)
	}
	return nil
}

func (p *Provider) Feed(ctx context.Context, _ string) (domain.Page, error) {
	var payload feedsData
	if err := p.request(ctx, http.MethodGet, "/api/v1/feeds/list", nil, &payload); err != nil {
		return domain.Page{}, err
	}
	return mapFeeds(payload.Feeds), nil
}

func (p *Provider) Browse(ctx context.Context, channel source.Channel, cursor string) (domain.Page, error) {
	switch channel {
	case source.ChannelRecommend:
		return p.Feed(ctx, cursor)
	case source.ChannelHot:
		page, err := p.Feed(ctx, cursor)
		if err != nil {
			return page, err
		}
		sort.SliceStable(page.Items, func(i, j int) bool {
			return localHeat(page.Items[i]) > localHeat(page.Items[j])
		})
		for index := range page.Items {
			page.Items[index].Tags = append(page.Items[index].Tags, "样本热度")
		}
		page.Notices = append(page.Notices, "小红书未提供官方热榜；当前按本次推荐样本的互动量排序")
		return page, nil
	case source.ChannelFollowing:
		return domain.Page{Notices: []string{"小红书 sidecar 暂未提供关注内容流；可在搜索中使用“已关注”筛选，但不能稳定生成完整关注首页"}}, nil
	default:
		return domain.Page{}, fmt.Errorf("未知小红书频道 %q", channel)
	}
}

func localHeat(item domain.Item) int64 {
	return item.Stats.Likes + item.Stats.Favorites*2 + item.Stats.Comments*3 + item.Stats.Shares*2
}

func (p *Provider) Search(ctx context.Context, query, _ string) (domain.Page, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return domain.Page{}, fmt.Errorf("请输入搜索词")
	}
	var payload feedsData
	path := "/api/v1/feeds/search?keyword=" + url.QueryEscape(query)
	if err := p.request(ctx, http.MethodGet, path, nil, &payload); err != nil {
		return domain.Page{}, err
	}
	return mapFeeds(payload.Feeds), nil
}

func (p *Provider) Detail(ctx context.Context, ref domain.Ref) (domain.Detail, error) {
	request := map[string]any{
		"feed_id": ref.ID, "xsec_token": ref.Token, "load_all_comments": false,
	}
	var payload struct {
		FeedID string         `json:"feed_id"`
		Data   feedDetailData `json:"data"`
	}
	if err := p.request(ctx, http.MethodPost, "/api/v1/feeds/detail", request, &payload); err != nil {
		return domain.Detail{}, err
	}
	note := payload.Data.Note
	item := mapFeed(feed{
		ID: note.NoteID, XsecToken: note.XsecToken,
		NoteCard: noteCard{DisplayTitle: note.Title, User: note.User, InteractInfo: note.InteractInfo},
	})
	item.Summary = note.Desc
	item.PublishedAt = xhsTime(note.Time)
	item.Ref = ref
	for _, image := range note.ImageList {
		imageURL := firstNonEmpty(image.URLDefault, image.URLPre)
		if imageURL != "" {
			item.Media = append(item.Media, domain.Media{Kind: "image", URL: imageURL, PreviewURL: imageURL, Width: image.Width, Height: image.Height})
		}
	}
	if stream, ok := selectVideoStream(note.Video); ok {
		duration := time.Duration(stream.Duration) * time.Millisecond
		if duration == 0 && note.Video != nil {
			duration = time.Duration(note.Video.Capa.Duration) * time.Second
		}
		item.Media = append(item.Media, domain.Media{
			Kind: "video", URL: stream.MasterURL, Format: firstNonEmpty(stream.StreamDesc, stream.QualityType, stream.Format),
			Width: stream.Width, Height: stream.Height, Duration: duration,
		})
	}
	detail := domain.Detail{Item: item, Body: note.Desc}
	for _, comment := range payload.Data.Comments.List {
		detail.Comments = append(detail.Comments, mapComment(comment, ref))
	}
	return detail, nil
}

func (p *Provider) Like(ctx context.Context, ref domain.Ref, value bool) error {
	return p.action(ctx, "/api/v1/feeds/like", map[string]any{
		"feed_id": ref.ID, "xsec_token": ref.Token, "unlike": !value,
	})
}

func (p *Provider) Favorite(ctx context.Context, ref domain.Ref, value bool) error {
	return p.action(ctx, "/api/v1/feeds/favorite", map[string]any{
		"feed_id": ref.ID, "xsec_token": ref.Token, "unfavorite": !value,
	})
}

func (p *Provider) Comment(ctx context.Context, ref domain.Ref, body string) error {
	return p.action(ctx, "/api/v1/feeds/comment", map[string]any{
		"feed_id": ref.ID, "xsec_token": ref.Token, "content": body,
	})
}

func (p *Provider) Reply(ctx context.Context, ref domain.Ref, comment domain.Ref, body string) error {
	return p.action(ctx, "/api/v1/feeds/comment/reply", map[string]any{
		"feed_id": ref.ID, "xsec_token": ref.Token, "comment_id": comment.ID, "content": body,
	})
}

func (p *Provider) action(ctx context.Context, path string, body any) error {
	var result struct {
		Success bool   `json:"success"`
		Message string `json:"message"`
	}
	if err := p.request(ctx, http.MethodPost, path, body, &result); err != nil {
		return err
	}
	if !result.Success && result.Message != "" {
		return fmt.Errorf("%s", result.Message)
	}
	return nil
}

type envelope struct {
	Success bool            `json:"success"`
	Data    json.RawMessage `json:"data"`
	Message string          `json:"message"`
	Error   string          `json:"error"`
	Code    string          `json:"code"`
	Details any             `json:"details"`
}

func (p *Provider) request(ctx context.Context, method, path string, input, output any) error {
	if err := p.requireSavedLogin(path); err != nil {
		return err
	}
	select {
	case p.requestGate <- struct{}{}:
		defer func() { <-p.requestGate }()
	case <-ctx.Done():
		return fmt.Errorf("等待小红书 sidecar 空闲: %w", ctx.Err())
	}
	var body io.Reader
	if input != nil {
		encoded, err := json.Marshal(input)
		if err != nil {
			return err
		}
		body = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, p.endpoint+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if input != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if p.token != "" {
		req.Header.Set("Authorization", "Bearer "+p.token)
	}
	res, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("连接小红书 sidecar %s: %w", p.endpoint, err)
	}
	defer res.Body.Close()
	encoded, err := io.ReadAll(io.LimitReader(res.Body, 16<<20))
	if err != nil {
		return fmt.Errorf("读取小红书响应: %w", err)
	}
	var response envelope
	if err := json.Unmarshal(encoded, &response); err != nil {
		return fmt.Errorf("解析小红书响应 (HTTP %d): %w", res.StatusCode, err)
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 || !response.Success {
		message := firstNonEmpty(response.Error, response.Message, strings.TrimSpace(string(encoded)))
		if response.Code != "" {
			message = response.Code + ": " + message
		}
		return fmt.Errorf("小红书 sidecar HTTP %d: %s", res.StatusCode, message)
	}
	if output != nil && len(response.Data) > 0 && string(response.Data) != "null" {
		if err := json.Unmarshal(response.Data, output); err != nil {
			return fmt.Errorf("解析小红书数据: %w", err)
		}
	}
	return nil
}

type feedsData struct {
	Feeds []feed `json:"feeds"`
	Count int    `json:"count"`
}

type feed struct {
	XsecToken string   `json:"xsecToken"`
	ID        string   `json:"id"`
	ModelType string   `json:"modelType"`
	NoteCard  noteCard `json:"noteCard"`
}

type noteCard struct {
	Type         string       `json:"type"`
	DisplayTitle string       `json:"displayTitle"`
	User         user         `json:"user"`
	InteractInfo interactInfo `json:"interactInfo"`
	Cover        cover        `json:"cover"`
	Video        *video       `json:"video,omitempty"`
}

type video struct {
	Capa videoCapability `json:"capa"`
}

type videoCapability struct {
	Duration int `json:"duration"`
}

type user struct {
	UserID   string `json:"userId"`
	Nickname string `json:"nickname"`
	NickName string `json:"nickName"`
	Avatar   string `json:"avatar"`
}

type interactInfo struct {
	Liked          bool   `json:"liked"`
	LikedCount     string `json:"likedCount"`
	SharedCount    string `json:"sharedCount"`
	CommentCount   string `json:"commentCount"`
	CollectedCount string `json:"collectedCount"`
	Collected      bool   `json:"collected"`
}

type cover struct {
	Width      int    `json:"width"`
	Height     int    `json:"height"`
	URL        string `json:"url"`
	URLPre     string `json:"urlPre"`
	URLDefault string `json:"urlDefault"`
	InfoList   []struct {
		URL string `json:"url"`
	} `json:"infoList"`
}

type detailImage struct {
	Width      int    `json:"width"`
	Height     int    `json:"height"`
	URLDefault string `json:"urlDefault"`
	URLPre     string `json:"urlPre"`
}

type videoDetail struct {
	Capa  videoCapability `json:"capa"`
	Media videoMedia      `json:"media"`
}

type videoMedia struct {
	Stream map[string][]videoStream `json:"stream"`
}

type videoStream struct {
	MasterURL     string   `json:"masterUrl"`
	BackupURLs    []string `json:"backupUrls"`
	Format        string   `json:"format"`
	Width         int      `json:"width"`
	Height        int      `json:"height"`
	Duration      int      `json:"duration"`
	QualityType   string   `json:"qualityType"`
	StreamDesc    string   `json:"streamDesc"`
	DefaultStream int      `json:"defaultStream"`
}

type feedDetailData struct {
	Note struct {
		NoteID       string        `json:"noteId"`
		XsecToken    string        `json:"xsecToken"`
		Title        string        `json:"title"`
		Desc         string        `json:"desc"`
		Time         int64         `json:"time"`
		User         user          `json:"user"`
		InteractInfo interactInfo  `json:"interactInfo"`
		ImageList    []detailImage `json:"imageList"`
		Video        *videoDetail  `json:"video,omitempty"`
	} `json:"note"`
	Comments struct {
		List    []comment `json:"list"`
		Cursor  string    `json:"cursor"`
		HasMore bool      `json:"hasMore"`
	} `json:"comments"`
}

type comment struct {
	ID          string    `json:"id"`
	NoteID      string    `json:"noteId"`
	Content     string    `json:"content"`
	LikeCount   string    `json:"likeCount"`
	CreateTime  int64     `json:"createTime"`
	UserInfo    user      `json:"userInfo"`
	SubComments []comment `json:"subComments"`
}

func mapFeeds(feeds []feed) domain.Page {
	page := domain.Page{Items: make([]domain.Item, 0, len(feeds))}
	for _, feed := range feeds {
		if feed.ID == "" || (feed.ModelType != "" && feed.ModelType != "note") {
			continue
		}
		page.Items = append(page.Items, mapFeed(feed))
	}
	return page
}

func mapFeed(feed feed) domain.Item {
	name := firstNonEmpty(feed.NoteCard.User.Nickname, feed.NoteCard.User.NickName)
	profile := xhsProfileRef(feed.NoteCard.User.UserID, feed.XsecToken)
	item := domain.Item{
		Ref: domain.Ref{
			Source: domain.SourceXHS, ID: feed.ID, Token: feed.XsecToken,
			URL: "https://www.xiaohongshu.com/explore/" + feed.ID + "?xsec_token=" + url.QueryEscape(feed.XsecToken),
		},
		Title:  feed.NoteCard.DisplayTitle,
		Author: domain.Author{Ref: profile, ID: feed.NoteCard.User.UserID, Name: name, Avatar: feed.NoteCard.User.Avatar},
		Stats: domain.Stats{
			Likes: parseCount(feed.NoteCard.InteractInfo.LikedCount), Comments: parseCount(feed.NoteCard.InteractInfo.CommentCount),
			Favorites: parseCount(feed.NoteCard.InteractInfo.CollectedCount), Shares: parseCount(feed.NoteCard.InteractInfo.SharedCount),
		},
		Liked: feed.NoteCard.InteractInfo.Liked, Favorited: feed.NoteCard.InteractInfo.Collected,
	}
	coverURL := firstNonEmpty(feed.NoteCard.Cover.URLDefault, feed.NoteCard.Cover.URLPre, feed.NoteCard.Cover.URL, firstCoverInfoURL(feed.NoteCard.Cover))
	if coverURL != "" {
		kind := "image"
		if feed.NoteCard.Type == "video" {
			kind = "video"
		}
		media := domain.Media{Kind: kind, PreviewURL: coverURL, Width: feed.NoteCard.Cover.Width, Height: feed.NoteCard.Cover.Height}
		if kind == "image" {
			media.URL = coverURL
		} else if feed.NoteCard.Video != nil {
			media.Duration = time.Duration(feed.NoteCard.Video.Capa.Duration) * time.Second
		}
		item.Media = append(item.Media, media)
	}
	return item
}

func xhsProfileRef(userID, token string) domain.ProfileRef {
	profile := domain.ProfileRef{Source: domain.SourceXHS, ID: userID, Token: token}
	if userID == "" {
		return profile
	}
	profile.URL = "https://www.xiaohongshu.com/user/profile/" + url.PathEscape(userID)
	if token != "" {
		profile.URL += "?xsec_token=" + url.QueryEscape(token) + "&xsec_source=pc_note"
	}
	return profile
}

func firstCoverInfoURL(cover cover) string {
	for _, info := range cover.InfoList {
		if strings.TrimSpace(info.URL) != "" {
			return info.URL
		}
	}
	return ""
}

func selectVideoStream(video *videoDetail) (videoStream, bool) {
	if video == nil {
		return videoStream{}, false
	}
	keys := make([]string, 0, len(video.Media.Stream))
	for codec := range video.Media.Stream {
		keys = append(keys, codec)
	}
	sort.SliceStable(keys, func(i, j int) bool {
		if keys[i] == "h264" {
			return true
		}
		if keys[j] == "h264" {
			return false
		}
		return keys[i] < keys[j]
	})
	var fallback videoStream
	for _, codec := range keys {
		for _, stream := range video.Media.Stream[codec] {
			stream.MasterURL = firstNonEmpty(stream.MasterURL, firstStringValue(stream.BackupURLs))
			if stream.MasterURL == "" {
				continue
			}
			if stream.DefaultStream != 0 {
				return stream, true
			}
			if fallback.MasterURL == "" || stream.Width*stream.Height < fallback.Width*fallback.Height {
				fallback = stream
			}
		}
		if fallback.MasterURL != "" && codec == "h264" {
			return fallback, true
		}
	}
	return fallback, fallback.MasterURL != ""
}

func firstStringValue(values []string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func mapComment(input comment, note domain.Ref) domain.Comment {
	name := firstNonEmpty(input.UserInfo.Nickname, input.UserInfo.NickName)
	result := domain.Comment{
		Ref:    domain.Ref{Source: domain.SourceXHS, ID: input.ID, ParentID: note.ID, Token: note.Token},
		Author: domain.Author{Ref: xhsProfileRef(input.UserInfo.UserID, ""), ID: input.UserInfo.UserID, Name: name, Avatar: input.UserInfo.Avatar},
		Body:   input.Content, Likes: parseCount(input.LikeCount), PublishedAt: xhsTime(input.CreateTime),
	}
	for _, sub := range input.SubComments {
		result.Replies = append(result.Replies, mapComment(sub, note))
	}
	return result
}

func parseCount(value string) int64 {
	value = strings.TrimSpace(strings.ReplaceAll(value, ",", ""))
	multiplier := float64(1)
	if strings.HasSuffix(value, "万") {
		value = strings.TrimSuffix(value, "万")
		multiplier = 10000
	}
	number, _ := strconv.ParseFloat(value, 64)
	return int64(number * multiplier)
}

func xhsTime(value int64) time.Time {
	if value == 0 {
		return time.Time{}
	}
	if value > 1_000_000_000_000 {
		return time.UnixMilli(value)
	}
	return time.Unix(value, 0)
}

func parseDuration(value string) time.Duration {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if duration, err := time.ParseDuration(value); err == nil {
		return duration
	}
	seconds, _ := strconv.Atoi(value)
	return time.Duration(seconds) * time.Second
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
