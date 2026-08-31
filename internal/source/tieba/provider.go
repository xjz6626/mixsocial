package tieba

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
)

const (
	legacyVersion       = "12.64.1.1"
	defaultRecommendURL = "https://tiebac.baidu.com/c/f/excellent/personalized?cmd=309264"
	defaultFRSURL       = "http://tiebac.baidu.com/c/f/frs/page?cmd=301001"
	defaultPBURL        = "https://tiebac.baidu.com/c/f/pb/page?cmd=302001"
	defaultFloorURL     = "https://tiebac.baidu.com/c/f/pb/floor?cmd=302002&format=protobuf"
)

type Config struct {
	Client       *http.Client
	Forums       []string
	PageSize     int
	RecommendURL string
	FRSURL       string
	PBURL        string
	FloorURL     string
	SearchURL    string
	LoginURL     string
	FollowURL    string
	HotURL       string
	BrowserPath  string
	SessionPath  string
}

type Provider struct {
	client       *http.Client
	clientID     string
	forums       []string
	pageSize     int
	recommendURL string
	frsURL       string
	pbURL        string
	floorURL     string
	searchURL    string
	loginURL     string
	followURL    string
	hotURL       string
	browserPath  string
	sessionPath  string

	sessionMu    sync.RWMutex
	session      sessionData
	sessionErr   error
	hotMu        sync.RWMutex
	hotItems     map[string]domain.Item
	browserMu    sync.Mutex
	browserLogin *browserLoginSession
}

func New(config Config) *Provider {
	client := config.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	pageSize := config.PageSize
	if pageSize <= 0 {
		pageSize = 20
	}
	frsURL := config.FRSURL
	if frsURL == "" {
		frsURL = defaultFRSURL
	}
	pbURL := config.PBURL
	if pbURL == "" {
		pbURL = defaultPBURL
	}
	floorURL := config.FloorURL
	if floorURL == "" {
		floorURL = defaultFloorURL
	}
	forums := make([]string, 0, len(config.Forums))
	for _, forum := range config.Forums {
		if forum = strings.TrimSpace(forum); forum != "" {
			forums = append(forums, forum)
		}
	}
	p := &Provider{
		client: client, clientID: fmt.Sprintf("wappc_%d_0", time.Now().UnixMilli()),
		forums: forums, pageSize: pageSize, recommendURL: config.RecommendURL, frsURL: frsURL, pbURL: pbURL, floorURL: floorURL,
		searchURL: config.SearchURL,
		loginURL:  config.LoginURL, followURL: config.FollowURL, hotURL: config.HotURL,
		browserPath: config.BrowserPath, sessionPath: config.SessionPath, hotItems: make(map[string]domain.Item),
	}
	if p.recommendURL == "" {
		p.recommendURL = defaultRecommendURL
	}
	if p.loginURL == "" {
		p.loginURL = defaultLoginURL
	}
	if p.searchURL == "" {
		p.searchURL = defaultSearchURL
	}
	if p.followURL == "" {
		p.followURL = defaultFollowURL
	}
	if p.hotURL == "" {
		p.hotURL = defaultHotURL
	}
	p.loadSession()
	return p
}

func (*Provider) ID() domain.SourceID { return domain.SourceTieba }
func (*Provider) Name() string        { return "百度贴吧" }
func (*Provider) Capabilities() source.Capability {
	return source.CapabilityFeed | source.CapabilitySearch | source.CapabilityDetail |
		source.CapabilityHot | source.CapabilityFollowing | source.CapabilityCredentialLogin |
		browserLoginCapability()
}

func (p *Provider) Feed(ctx context.Context, cursor string) (domain.Page, error) {
	return p.Browse(ctx, source.ChannelRecommend, cursor)
}

func (p *Provider) Browse(ctx context.Context, channel source.Channel, cursor string) (domain.Page, error) {
	forums := append([]string(nil), p.forums...)
	sortType := 6
	var notices []string

	switch channel {
	case source.ChannelRecommend:
		if len(forums) == 0 {
			return p.personalized(ctx, cursor)
		}
	case source.ChannelHot:
		page, err := p.hotTopics(ctx)
		if err == nil {
			return page, nil
		}
		sortType = 3
		if len(forums) == 0 && p.hasSession() {
			followed, err := p.followedForumNames(ctx)
			if err != nil {
				return domain.Page{}, err
			}
			forums = followed
		}
		notices = append(notices, "贴吧全站热议榜暂不可用，已回退到常看吧或已关注贴吧的热门主题: "+err.Error())
	case source.ChannelFollowing:
		if !p.hasSession() {
			return domain.Page{}, fmt.Errorf("贴吧关注频道需要登录；切到贴吧来源后按 L 扫码，或按 B 导入 BDUSS")
		}
		followed, err := p.followedForumNames(ctx)
		if err != nil {
			return domain.Page{}, err
		}
		forums = followed
		notices = append(notices, "贴吧关注频道汇总账号已关注的贴吧")
	default:
		return domain.Page{}, fmt.Errorf("未知贴吧频道 %q", channel)
	}

	if len(forums) == 0 {
		return domain.Page{Notices: append(notices, "贴吧尚未配置常看吧；可搜索吧名、设置 --tieba-forums，或登录后使用已关注贴吧")}, nil
	}
	const maxForums = 8
	if len(forums) > maxForums {
		forums = forums[:maxForums]
		notices = append(notices, "为控制请求频率，本次只读取前 8 个贴吧")
	}
	page, err := p.feedForums(ctx, forums, cursor, sortType)
	page.Notices = append(notices, page.Notices...)
	return page, err
}

func (p *Provider) feedForums(ctx context.Context, forums []string, cursor string, sortType int) (domain.Page, error) {
	type result struct {
		page domain.Page
		err  error
		name string
	}
	results := make(chan result, len(forums))
	var wg sync.WaitGroup
	for _, forum := range forums {
		wg.Add(1)
		go func(forum string) {
			defer wg.Done()
			page, err := p.searchForum(ctx, forum, cursor, sortType)
			results <- result{page: page, err: err, name: forum}
		}(forum)
	}
	wg.Wait()
	close(results)

	var page domain.Page
	var failures []string
	for result := range results {
		if result.err != nil {
			failures = append(failures, result.name+"吧: "+result.err.Error())
			continue
		}
		page.Items = append(page.Items, result.page.Items...)
		page.HasMore = page.HasMore || result.page.HasMore
	}
	sort.SliceStable(page.Items, func(i, j int) bool {
		return page.Items[i].PublishedAt.After(page.Items[j].PublishedAt)
	})
	for _, failure := range failures {
		page.Notices = append(page.Notices, "贴吧 "+failure)
	}
	if len(page.Items) == 0 && len(failures) > 0 {
		return page, fmt.Errorf("%s", strings.Join(failures, "; "))
	}
	return page, nil
}

func (p *Provider) Search(ctx context.Context, query, cursor string) (domain.Page, error) {
	return p.searchThreads(ctx, query, cursor)
}

// Forum reads one forum without changing the provider's configured home feed.
// sortType follows the public FRS values: 0 orders by latest reply and 1 by
// thread creation time.
func (p *Provider) Forum(ctx context.Context, forum, cursor string, sortType int) (domain.Page, error) {
	forum = strings.TrimSpace(strings.TrimSuffix(forum, "吧"))
	if forum == "" {
		return domain.Page{}, fmt.Errorf("请输入贴吧吧名")
	}
	if sortType != 1 {
		sortType = 0
	}
	return p.searchForum(ctx, forum, cursor, sortType)
}

// FollowingForums returns the names used by the account's forum directory.
func (p *Provider) FollowingForums(ctx context.Context) ([]string, error) {
	return p.followedForumNames(ctx)
}

func (p *Provider) searchForum(ctx context.Context, forum, cursor string, sortType int) (domain.Page, error) {
	pageNumber := positiveInt(cursor, 1)
	body := encodeThreadsRequest(forum, pageNumber, p.pageSize, sortType)
	response, err := p.postProto(ctx, p.frsURL, body)
	if err != nil {
		return domain.Page{}, err
	}
	return decodeThreadsResponse(response, forum, pageNumber)
}

func (p *Provider) Detail(ctx context.Context, ref domain.Ref) (domain.Detail, error) {
	return p.DetailPage(ctx, ref, "", false, false)
}

// DetailPage reads one page of replies. reverse and onlyOriginalPoster map to
// Tieba's PB page sorting flags and are intentionally read-only operations.
func (p *Provider) DetailPage(ctx context.Context, ref domain.Ref, cursor string, reverse, onlyOriginalPoster bool) (domain.Detail, error) {
	if ref.Token == hotTopicToken {
		return p.hotTopicDetail(ctx, ref)
	}
	tid, err := strconv.ParseUint(ref.ID, 10, 64)
	if err != nil || tid == 0 {
		return domain.Detail{}, fmt.Errorf("invalid Tieba thread id %q", ref.ID)
	}
	pageNumber := positiveInt(cursor, 1)
	body := encodePostsRequest(tid, pageNumber, 30, reverse, onlyOriginalPoster)
	response, err := p.postProto(ctx, p.pbURL, body)
	if err != nil {
		return domain.Detail{}, err
	}
	return decodePostsResponse(response, ref, pageNumber)
}

// FloorReplies reads every nested reply for one floor. The comment reference
// carries the thread ID in ParentID and the numeric forum ID in Token.
func (p *Provider) FloorReplies(ctx context.Context, ref domain.Ref, cursor string) (domain.CommentPage, error) {
	tid, tidErr := strconv.ParseUint(ref.ParentID, 10, 64)
	pid, pidErr := strconv.ParseUint(ref.ID, 10, 64)
	if tidErr != nil || pidErr != nil || tid == 0 || pid == 0 {
		return domain.CommentPage{}, fmt.Errorf("invalid Tieba floor reference")
	}
	forumID, _ := strconv.ParseUint(ref.Token, 10, 64)
	pageNumber := positiveInt(cursor, 1)
	response, err := p.postProto(ctx, p.floorURL, encodeFloorRepliesRequest(tid, pid, forumID, pageNumber))
	if err != nil {
		return domain.CommentPage{}, err
	}
	return decodeFloorRepliesResponse(response, ref, pageNumber)
}

func (p *Provider) postProto(ctx context.Context, endpoint string, protoBody []byte) ([]byte, error) {
	return p.postProtoWithSession(ctx, endpoint, protoBody, nil)
}

func (p *Provider) postProtoWithSession(ctx context.Context, endpoint string, protoBody []byte, session *sessionData) ([]byte, error) {
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	// The boundary is arbitrary. Keep it MIME-compliant so Go and proxies can
	// parse it consistently; the upstream client-specific value is not required.
	if err := writer.SetBoundary("mixsocial-r1999"); err != nil {
		return nil, err
	}
	if session != nil && session.STOKEN != "" {
		if err := writer.WriteField("stoken", session.STOKEN); err != nil {
			return nil, err
		}
	}
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", `form-data; name="data"; filename="file"`)
	part, err := writer.CreatePart(header)
	if err != nil {
		return nil, err
	}
	if _, err = part.Write(protoBody); err != nil {
		return nil, err
	}
	if err = writer.Close(); err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, &body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("User-Agent", "mixsocial-tui/0.1")
	req.Header.Set("x_bd_data_type", "protobuf")
	req.Header.Set("Accept-Encoding", "gzip")
	req.Header.Set("Connection", "keep-alive")
	if session != nil {
		req.Header.Set("Charset", "UTF-8")
		req.Header.Set("client_type", "2")
		req.Header.Set("cuid", p.clientID)
		req.Header.Set("cuid_galaxy2", p.clientID)
		req.Header.Set("cuid_gid", "")
		req.Header.Set("Cookie", "CUID="+p.clientID+"; ka=open; TBBRAND=mixsocial")
		req.Header.Set("User-Agent", personalizedUserAgent)
		if session.UserID != "" {
			req.Header.Set("client_user_token", session.UserID)
		}
	}

	res, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request Tieba: %w", err)
	}
	defer res.Body.Close()
	var reader io.Reader = res.Body
	if strings.EqualFold(res.Header.Get("Content-Encoding"), "gzip") {
		gzipReader, gzipErr := gzip.NewReader(res.Body)
		if gzipErr != nil {
			return nil, fmt.Errorf("decode Tieba gzip: %w", gzipErr)
		}
		defer gzipReader.Close()
		reader = gzipReader
	}
	data, err := io.ReadAll(io.LimitReader(reader, 8<<20))
	if err != nil {
		return nil, fmt.Errorf("read Tieba response: %w", err)
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, fmt.Errorf("Tieba HTTP %d: %s", res.StatusCode, strings.TrimSpace(string(data)))
	}
	return data, nil
}

func encodeCommon() []byte {
	var common []byte
	common = appendUint(common, 1, 2)
	common = appendString(common, 2, legacyVersion)
	return common
}

func encodeThreadsRequest(forum string, page, size, sortType int) []byte {
	var data []byte
	data = appendString(data, 1, forum)
	data = appendUint(data, 2, uint64(size))
	data = appendUint(data, 3, uint64(size+5))
	if page > 1 {
		data = appendUint(data, 15, uint64(page))
	}
	data = appendUint(data, 47, uint64(sortType))
	data = appendBytes(data, 39, encodeCommon())
	return appendBytes(nil, 1, data)
}

func encodePostsRequest(tid uint64, page, size int, reverse, onlyOriginalPoster bool) []byte {
	var data []byte
	data = appendUint(data, 4, tid)
	if onlyOriginalPoster {
		data = appendUint(data, 5, 1)
	}
	if reverse {
		data = appendUint(data, 6, 1)
	}
	data = appendUint(data, 8, 1)
	data = appendUint(data, 9, 3)
	data = appendUint(data, 13, uint64(max(size, 2)))
	data = appendUint(data, 18, uint64(page))
	data = appendBytes(data, 25, encodeCommon())
	return appendBytes(nil, 1, data)
}

func encodeFloorRepliesRequest(tid, pid, forumID uint64, page int) []byte {
	var data []byte
	data = appendUint(data, 1, tid)
	data = appendUint(data, 2, pid)
	data = appendUint(data, 4, uint64(page))
	data = appendBytes(data, 9, encodeCommon())
	data = appendUint(data, 11, forumID)
	return appendBytes(nil, 1, data)
}

func decodeThreadsResponse(body []byte, forum string, pageNumber int) (domain.Page, error) {
	root, err := parseFields(body)
	if err != nil {
		return domain.Page{}, fmt.Errorf("decode Tieba response: %w", err)
	}
	if err := responseError(root); err != nil {
		return domain.Page{}, err
	}
	data, err := parseFields(firstBytes(root, 2))
	if err != nil {
		return domain.Page{}, fmt.Errorf("decode Tieba data: %w", err)
	}
	page := domain.Page{}
	users := decodeUsers(allBytes(data, 17))
	if pageFields, parseErr := parseFields(firstBytes(data, 4)); parseErr == nil {
		page.HasMore = firstUint(pageFields, 6) != 0
		if page.HasMore {
			page.NextCursor = strconv.Itoa(pageNumber + 1)
		}
	}
	for _, encoded := range allBytes(data, 7) {
		item, parseErr := decodeThread(encoded, forum)
		if parseErr == nil && item.Ref.ID != "" && item.Title != "" {
			if author, ok := users[item.Author.ID]; ok {
				item.Author = author
			}
			page.Items = append(page.Items, item)
		}
	}
	return page, nil
}

func decodeThread(encoded []byte, fallbackForum string) (domain.Item, error) {
	fields, err := parseFields(encoded)
	if err != nil {
		return domain.Item{}, err
	}
	tid := firstUint(fields, 1)
	forum := firstString(fields, 28)
	if forum == "" {
		if forumFields, parseErr := parseFields(firstBytes(fields, 155)); parseErr == nil {
			forum = firstString(forumFields, 2)
		}
	}
	if forum == "" {
		forum = fallbackForum
	}
	contents := allBytes(fields, 142)
	summary, contentMedia := decodeContents(contents)
	richSummary, richMedia := decodeContents(allBytes(fields, 112))
	if summary == "" {
		summary = richSummary
	}
	contentMedia = append(contentMedia, richMedia...)
	if summary == "" {
		summary, _ = decodeContents(allBytes(fields, 21))
	}
	media := appendUniqueMedia(nil, contentMedia...)
	for _, raw := range allBytes(fields, 22) {
		if decoded, ok := decodeThreadMedia(raw); ok {
			media = appendUniqueMedia(media, decoded)
		}
	}
	if decoded, ok := decodeVideoInfo(firstBytes(fields, 79)); ok {
		media = appendUniqueMedia(media, decoded)
	}
	if originFields, parseErr := parseFields(firstBytes(fields, 141)); parseErr == nil {
		originSummary, originContentMedia := decodeContents(allBytes(originFields, 14))
		if summary == "" {
			summary = originSummary
		}
		media = appendUniqueMedia(media, originContentMedia...)
		for _, raw := range allBytes(originFields, 2) {
			if decoded, ok := decodeThreadMedia(raw); ok {
				media = appendUniqueMedia(media, decoded)
			}
		}
		if decoded, ok := decodeVideoInfo(firstBytes(originFields, 13)); ok {
			media = appendUniqueMedia(media, decoded)
		}
	}
	author, _ := decodeAuthor(firstBytes(fields, 18))
	if author.ID == "0" || author.ID == "" {
		author.ID = strconv.FormatUint(firstUint(fields, 56), 10)
	}
	timestamp := firstUint(fields, 45)
	if timestamp == 0 {
		timestamp = firstUint(fields, 7)
	}
	var tags []string
	if forum != "" {
		tags = []string{forum + "吧"}
	}
	return domain.Item{
		Ref: domain.Ref{
			Source: domain.SourceTieba, ID: strconv.FormatUint(tid, 10),
			URL: "https://tieba.baidu.com/p/" + strconv.FormatUint(tid, 10),
		},
		Title: firstString(fields, 3), Summary: summary, Author: author,
		PublishedAt: unixTime(timestamp), Media: media, Tags: tags,
		Stats: domain.Stats{
			Comments: int64(firstUint(fields, 4)), Views: int64(firstUint(fields, 5)),
			Likes: int64(firstUint(fields, 124)), Shares: int64(firstUint(fields, 135)),
		},
	}, nil
}

func decodePostsResponse(body []byte, ref domain.Ref, pageNumber int) (domain.Detail, error) {
	root, err := parseFields(body)
	if err != nil {
		return domain.Detail{}, fmt.Errorf("decode Tieba response: %w", err)
	}
	if err := responseError(root); err != nil {
		return domain.Detail{}, err
	}
	data, err := parseFields(firstBytes(root, 2))
	if err != nil {
		return domain.Detail{}, fmt.Errorf("decode Tieba data: %w", err)
	}
	item, _ := decodeThread(firstBytes(data, 8), "")
	if forumFields, parseErr := parseFields(firstBytes(data, 2)); parseErr == nil {
		if forumID := firstUint(forumFields, 1); forumID != 0 {
			ref.Token = strconv.FormatUint(forumID, 10)
		}
	}
	item.Ref = ref
	users := decodeUsers(allBytes(data, 13))
	if author, ok := users[item.Author.ID]; ok {
		item.Author = author
	}
	posts := allBytes(data, 6)
	var detail domain.Detail
	detail.Item = item
	if pageFields, parseErr := parseFields(firstBytes(data, 3)); parseErr == nil {
		detail.HasMore = firstUint(pageFields, 6) != 0
		if detail.HasMore {
			detail.NextCursor = strconv.Itoa(pageNumber + 1)
		}
	}
	if encodedMain := firstBytes(data, 38); len(encodedMain) > 0 {
		if mainPost, parseErr := decodePost(encodedMain, ref); parseErr == nil {
			applyMainPost(&detail, mainPost, users)
		}
	}
	for _, encoded := range posts {
		post, parseErr := decodePost(encoded, ref)
		if parseErr != nil {
			continue
		}
		if author, ok := users[post.Author.ID]; ok {
			post.Author = author
		}
		if post.Floor == 1 {
			applyMainPost(&detail, post, users)
			continue
		}
		detail.Comments = append(detail.Comments, post)
	}
	if detail.Title == "" {
		detail.Title = "贴吧主题 " + ref.ID
	}
	return detail, nil
}

func decodeFloorRepliesResponse(body []byte, floorRef domain.Ref, pageNumber int) (domain.CommentPage, error) {
	root, err := parseFields(body)
	if err != nil {
		return domain.CommentPage{}, fmt.Errorf("decode Tieba floor response: %w", err)
	}
	if err := responseError(root); err != nil {
		return domain.CommentPage{}, err
	}
	data, err := parseFields(firstBytes(root, 2))
	if err != nil {
		return domain.CommentPage{}, fmt.Errorf("decode Tieba floor data: %w", err)
	}
	threadRef := domain.Ref{
		Source: domain.SourceTieba,
		ID:     floorRef.ParentID,
		Token:  floorRef.Token,
		URL:    floorRef.URL,
	}
	page := domain.CommentPage{}
	if pageFields, parseErr := parseFields(firstBytes(data, 1)); parseErr == nil {
		page.HasMore = firstUint(pageFields, 6) != 0
		if page.HasMore {
			page.NextCursor = strconv.Itoa(pageNumber + 1)
		}
	}
	for _, raw := range allBytes(data, 4) {
		reply, parseErr := decodeSubPost(raw, threadRef, floorRef.ID)
		if parseErr == nil && reply.Ref.ID != "0" && (reply.Body != "" || len(reply.Media) > 0) {
			page.Comments = append(page.Comments, reply)
		}
	}
	return page, nil
}

func applyMainPost(detail *domain.Detail, post domain.Comment, users map[string]domain.Author) {
	if author, ok := users[post.Author.ID]; ok {
		post.Author = author
	}
	detail.Body = post.Body
	detail.Media = appendUniqueMedia(detail.Media, post.Media...)
	if detail.Author.Name == "" {
		detail.Author = post.Author
	}
	if detail.PublishedAt.IsZero() {
		detail.PublishedAt = post.PublishedAt
	}
}

func appendUniqueMedia(existing []domain.Media, additions ...domain.Media) []domain.Media {
	seen := make(map[string]int, len(existing)+len(additions))
	for index, media := range existing {
		seen[mediaIdentity(media)] = index
	}
	for _, media := range additions {
		key := mediaIdentity(media)
		if key == "\x00" {
			continue
		}
		if index, ok := seen[key]; ok {
			current := &existing[index]
			if media.URL != "" && current.URL == "" {
				current.URL = media.URL
			}
			if media.PreviewURL != "" && (current.PreviewURL == "" || current.PreviewURL == current.URL) {
				current.PreviewURL = media.PreviewURL
			}
			if current.Width == 0 {
				current.Width = media.Width
			}
			if current.Height == 0 {
				current.Height = media.Height
			}
			if current.Duration == 0 {
				current.Duration = media.Duration
			}
			continue
		}
		seen[key] = len(existing)
		existing = append(existing, media)
	}
	return existing
}

func mediaIdentity(media domain.Media) string {
	// Tieba exposes alternate transcodes for the same one-video post in
	// PbContent and VideoInfo. Keep the first playable variant instead of
	// rendering the same post as multiple videos.
	if media.Kind == "video" {
		return "video\x00"
	}
	identityURL := media.URL
	if identityURL == "" {
		identityURL = media.PreviewURL
	}
	if identityURL == "" {
		return "\x00"
	}
	return media.Kind + "\x00" + identityURL
}

func decodePost(encoded []byte, threadRef domain.Ref) (domain.Comment, error) {
	fields, err := parseFields(encoded)
	if err != nil {
		return domain.Comment{}, err
	}
	body, contentMedia := decodeContents(allBytes(fields, 5))
	media := appendUniqueMedia(nil, contentMedia...)
	if decoded, ok := decodeVideoInfo(firstBytes(fields, 29)); ok {
		media = appendUniqueMedia(media, decoded)
	}
	if len(media) == 0 {
		for _, rawURL := range allBytes(fields, 6) {
			if videoURL := normalizeTiebaMediaURL(string(rawURL)); videoURL != "" {
				media = appendUniqueMedia(media, domain.Media{Kind: "video", URL: videoURL})
			}
		}
	}
	author, _ := decodeAuthor(firstBytes(fields, 23))
	if author.ID == "0" || author.ID == "" {
		author.ID = strconv.FormatUint(firstUint(fields, 19), 10)
	}
	postID := strconv.FormatUint(firstUint(fields, 1), 10)
	comment := domain.Comment{
		Ref:    domain.Ref{Source: domain.SourceTieba, ID: strconv.FormatUint(firstUint(fields, 1), 10), ParentID: threadRef.ID, Token: threadRef.Token, URL: threadRef.URL},
		Author: author, Body: body, PublishedAt: unixTime(firstUint(fields, 4)),
		Floor: int(firstUint(fields, 3)), ReplyCount: int64(firstUint(fields, 13)), Media: media,
	}
	if agreeFields, parseErr := parseFields(firstBytes(fields, 37)); parseErr == nil {
		comment.Likes = int64(firstUint(agreeFields, 1))
	}
	comment.Replies = decodeSubPosts(firstBytes(fields, 15), threadRef, postID)
	return comment, nil
}

func decodeSubPosts(encoded []byte, threadRef domain.Ref, parentPostID string) []domain.Comment {
	container, err := parseFields(encoded)
	if err != nil {
		return nil
	}
	var replies []domain.Comment
	for _, raw := range allBytes(container, 2) {
		reply, parseErr := decodeSubPost(raw, threadRef, parentPostID)
		if parseErr != nil {
			continue
		}
		if reply.Ref.ID != "0" && (reply.Body != "" || len(reply.Media) > 0) {
			replies = append(replies, reply)
		}
	}
	return replies
}

func decodeSubPost(raw []byte, threadRef domain.Ref, parentPostID string) (domain.Comment, error) {
	fields, err := parseFields(raw)
	if err != nil {
		return domain.Comment{}, err
	}
	body, media := decodeContents(allBytes(fields, 2))
	author, _ := decodeAuthor(firstBytes(fields, 7))
	if author.ID == "0" || author.ID == "" {
		author.ID = strconv.FormatUint(firstUint(fields, 4), 10)
		author.Ref = domain.ProfileRef{Source: domain.SourceTieba, ID: author.ID}
	}
	reply := domain.Comment{
		Ref: domain.Ref{
			Source: domain.SourceTieba, ID: strconv.FormatUint(firstUint(fields, 1), 10),
			ParentID: parentPostID, Token: threadRef.Token, URL: threadRef.URL,
		},
		Author: author, Body: body, PublishedAt: unixTime(firstUint(fields, 3)),
		Floor: int(firstUint(fields, 6)), Media: media,
	}
	if agreeFields, agreeErr := parseFields(firstBytes(fields, 9)); agreeErr == nil {
		reply.Likes = int64(firstUint(agreeFields, 1))
	}
	return reply, nil
}

func decodeAuthor(encoded []byte) (domain.Author, error) {
	fields, err := parseFields(encoded)
	if err != nil {
		return domain.Author{}, err
	}
	name := firstString(fields, 4)
	if name == "" {
		name = firstString(fields, 3)
	}
	portrait := firstString(fields, 5)
	id := strconv.FormatUint(firstUint(fields, 2), 10)
	profile := domain.ProfileRef{Source: domain.SourceTieba, ID: id}
	if name != "" {
		profile.URL = "https://tieba.baidu.com/home/main?un=" + url.QueryEscape(name)
	}
	return domain.Author{Ref: profile, ID: id, Name: name, Avatar: tiebaAvatarURL(portrait)}, nil
}

func tiebaAvatarURL(portrait string) string {
	portrait = strings.TrimSpace(portrait)
	if portrait == "" {
		return ""
	}
	if strings.HasPrefix(portrait, "//") {
		portrait = "https:" + portrait
	}
	if parsed, err := url.Parse(portrait); err == nil && parsed.Host != "" && (parsed.Scheme == "http" || parsed.Scheme == "https") {
		// tb.himg.baidu.com only serves portraits over HTTP and presents a
		// certificate for another hostname on HTTPS. himg.bdimg.com exposes the
		// same files over valid HTTPS, which Android can load without permitting
		// cleartext traffic.
		if strings.EqualFold(parsed.Hostname(), "tb.himg.baidu.com") {
			parsed.Scheme = "https"
			parsed.Host = "himg.bdimg.com"
		}
		return parsed.String()
	}
	// Portrait identifiers may include a cache-busting query such as
	// "?t=1711009997". Treat it as a relative URL so '?' is not escaped into
	// the filename (which makes the CDN return 404).
	parsed, err := url.Parse(portrait)
	if err != nil || parsed.Path == "" {
		return ""
	}
	return (&url.URL{
		Scheme:   "https",
		Host:     "himg.bdimg.com",
		Path:     "/sys/portrait/item/" + parsed.Path,
		RawQuery: parsed.RawQuery,
	}).String()
}

func decodeUsers(encoded [][]byte) map[string]domain.Author {
	users := make(map[string]domain.Author, len(encoded))
	for _, raw := range encoded {
		author, err := decodeAuthor(raw)
		if err == nil && author.ID != "" && author.ID != "0" {
			users[author.ID] = author
		}
	}
	return users
}

func decodeContents(encoded [][]byte) (string, []domain.Media) {
	var textParts []string
	var media []domain.Media
	for _, raw := range encoded {
		fields, err := parseFields(raw)
		if err != nil {
			continue
		}
		if firstUint(fields, 1) == 2 {
			// PbContent type 2 is an inline emoticon. Field 2 contains an
			// implementation resource name (for example image_emoticon25),
			// while field 11 contains the human-readable name (滑稽).
			if label := strings.TrimSpace(firstString(fields, 11)); label != "" {
				textParts = append(textParts, "#("+label+")")
			}
			continue
		}
		if text := strings.TrimSpace(firstString(fields, 2)); text != "" {
			textParts = append(textParts, text)
		}
		if firstUint(fields, 1) == 5 {
			videoURL := normalizeTiebaMediaURL(firstString(fields, 3))
			previewURL := normalizeTiebaMediaURL(firstString(fields, 4))
			if videoURL != "" || previewURL != "" {
				width, height := contentDimensions(fields)
				media = append(media, domain.Media{
					Kind: "video", URL: videoURL, PreviewURL: previewURL,
					Width: width, Height: height,
					Duration: time.Duration(firstUint(fields, 13)) * time.Second,
				})
			}
			continue
		}
		imageURL := ""
		// Mirrors TiebaLite's PbContent.picUrl fallback order. Different
		// thread types populate different CDN/original fields.
		for _, fieldNumber := range []int{25, 9, 6, 16, 8, 36, 4, 17} {
			if imageURL = normalizeTiebaMediaURL(firstString(fields, fieldNumber)); imageURL != "" {
				break
			}
		}
		if imageURL != "" {
			width, height := contentDimensions(fields)
			media = append(media, domain.Media{Kind: "image", URL: imageURL, PreviewURL: imageURL, Width: width, Height: height})
		}
	}
	return strings.Join(textParts, ""), media
}

// decodeThreadMedia maps ThreadInfo.media and OriginThreadInfo.media. Tieba's
// forum-list response usually stores pictures here instead of firstPostContent.
func decodeThreadMedia(encoded []byte) (domain.Media, bool) {
	fields, err := parseFields(encoded)
	if err != nil {
		return domain.Media{}, false
	}
	fullURL := firstNonEmptyTiebaMediaURL(fields, 15, 18, 3, 8)
	previewURL := firstNonEmptyTiebaMediaURL(fields, 3, 8, 18, 15)
	if fullURL == "" && previewURL == "" {
		return domain.Media{}, false
	}
	return domain.Media{
		Kind: "image", URL: fullURL, PreviewURL: previewURL,
		Width: int(firstUint(fields, 10)), Height: int(firstUint(fields, 11)),
	}, true
}

// decodeVideoInfo maps the standalone video payload used by both ThreadInfo
// (field 79) and Post (field 29). It is not embedded in PbContent on many posts.
func decodeVideoInfo(encoded []byte) (domain.Media, bool) {
	fields, err := parseFields(encoded)
	if err != nil {
		return domain.Media{}, false
	}
	videoURL := normalizeTiebaMediaURL(firstString(fields, 2))
	previewURL := normalizeTiebaMediaURL(firstString(fields, 6))
	if videoURL == "" && previewURL == "" {
		return domain.Media{}, false
	}
	width := int(firstUint(fields, 4))
	height := int(firstUint(fields, 5))
	if width == 0 || height == 0 {
		width = int(firstUint(fields, 7))
		height = int(firstUint(fields, 8))
	}
	return domain.Media{
		Kind: "video", URL: videoURL, PreviewURL: previewURL,
		Width: width, Height: height,
		Duration: time.Duration(firstUint(fields, 3)) * time.Second,
	}, true
}

func firstNonEmptyTiebaMediaURL(fields []wireField, fieldNumbers ...int) string {
	for _, fieldNumber := range fieldNumbers {
		if value := normalizeTiebaMediaURL(firstString(fields, fieldNumber)); value != "" {
			return value
		}
	}
	return ""
}

func normalizeTiebaMediaURL(value string) string {
	value = strings.TrimSpace(strings.ReplaceAll(value, `\/`, "/"))
	if value == "" {
		return ""
	}
	if strings.HasPrefix(value, "//") {
		return "https:" + value
	}
	parsed, err := url.Parse(value)
	if err == nil && parsed.Scheme == "http" && parsed.Host != "" {
		parsed.Scheme = "https"
		return parsed.String()
	}
	return value
}

func contentDimensions(fields []wireField) (int, int) {
	width := int(firstUint(fields, 18))
	height := int(firstUint(fields, 19))
	if width > 0 && height > 0 {
		return width, height
	}
	parts := strings.SplitN(firstString(fields, 5), ",", 2)
	if len(parts) == 2 {
		if parsed, err := strconv.Atoi(strings.TrimSpace(parts[0])); err == nil {
			width = parsed
		}
		if parsed, err := strconv.Atoi(strings.TrimSpace(parts[1])); err == nil {
			height = parsed
		}
	}
	return width, height
}

func responseError(root []wireField) error {
	errorFields, err := parseFields(firstBytes(root, 1))
	if err != nil {
		return fmt.Errorf("decode Tieba error: %w", err)
	}
	if code := int64(firstUint(errorFields, 1)); code != 0 {
		return fmt.Errorf("Tieba API %d: %s", code, firstString(errorFields, 2))
	}
	return nil
}

func unixTime(value uint64) time.Time {
	if value == 0 {
		return time.Time{}
	}
	return time.Unix(int64(value), 0)
}

func positiveInt(value string, fallback int) int {
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 1 {
		return fallback
	}
	return parsed
}
