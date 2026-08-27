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
	legacyVersion = "12.64.1.1"
	defaultFRSURL = "http://tiebac.baidu.com/c/f/frs/page?cmd=301001"
	defaultPBURL  = "https://tiebac.baidu.com/c/f/pb/page?cmd=302001"
)

type Config struct {
	Client      *http.Client
	Forums      []string
	PageSize    int
	FRSURL      string
	PBURL       string
	LoginURL    string
	FollowURL   string
	HotURL      string
	BrowserPath string
	SessionPath string
}

type Provider struct {
	client      *http.Client
	forums      []string
	pageSize    int
	frsURL      string
	pbURL       string
	loginURL    string
	followURL   string
	hotURL      string
	browserPath string
	sessionPath string

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
	forums := make([]string, 0, len(config.Forums))
	for _, forum := range config.Forums {
		if forum = strings.TrimSpace(forum); forum != "" {
			forums = append(forums, forum)
		}
	}
	p := &Provider{
		client: client, forums: forums, pageSize: pageSize, frsURL: frsURL, pbURL: pbURL,
		loginURL: config.LoginURL, followURL: config.FollowURL, hotURL: config.HotURL,
		browserPath: config.BrowserPath, sessionPath: config.SessionPath, hotItems: make(map[string]domain.Item),
	}
	if p.loginURL == "" {
		p.loginURL = defaultLoginURL
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
		if len(forums) == 0 && p.hasSession() {
			followed, err := p.followedForumNames(ctx)
			if err != nil {
				return domain.Page{}, err
			}
			forums = followed
			notices = append(notices, "贴吧推荐未配置常看吧，当前使用已关注贴吧")
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

// Search interprets the query as a Tieba forum name. Full-site post search is a
// separate, less stable web endpoint and is deliberately not hidden behind this call.
func (p *Provider) Search(ctx context.Context, query, cursor string) (domain.Page, error) {
	forum := strings.TrimSpace(strings.TrimSuffix(query, "吧"))
	if forum == "" {
		return domain.Page{}, fmt.Errorf("请输入贴吧吧名")
	}
	return p.searchForum(ctx, forum, cursor, 6)
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
	if ref.Token == hotTopicToken {
		return p.hotTopicDetail(ctx, ref)
	}
	tid, err := strconv.ParseUint(ref.ID, 10, 64)
	if err != nil || tid == 0 {
		return domain.Detail{}, fmt.Errorf("invalid Tieba thread id %q", ref.ID)
	}
	body := encodePostsRequest(tid, 1, 30)
	response, err := p.postProto(ctx, p.pbURL, body)
	if err != nil {
		return domain.Detail{}, err
	}
	return decodePostsResponse(response, ref)
}

func (p *Provider) postProto(ctx context.Context, endpoint string, protoBody []byte) ([]byte, error) {
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	// The boundary is arbitrary. Keep it MIME-compliant so Go and proxies can
	// parse it consistently; the upstream client-specific value is not required.
	if err := writer.SetBoundary("mixsocial-r1999"); err != nil {
		return nil, err
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

func encodePostsRequest(tid uint64, page, size int) []byte {
	var data []byte
	data = appendUint(data, 4, tid)
	data = appendUint(data, 13, uint64(max(size, 2)))
	data = appendUint(data, 18, uint64(page))
	data = appendBytes(data, 25, encodeCommon())
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
		forum = fallbackForum
	}
	contents := allBytes(fields, 142)
	summary, media := decodeContents(contents)
	author, _ := decodeAuthor(firstBytes(fields, 18))
	if author.ID == "0" || author.ID == "" {
		author.ID = strconv.FormatUint(firstUint(fields, 56), 10)
	}
	timestamp := firstUint(fields, 45)
	if timestamp == 0 {
		timestamp = firstUint(fields, 7)
	}
	return domain.Item{
		Ref: domain.Ref{
			Source: domain.SourceTieba, ID: strconv.FormatUint(tid, 10),
			URL: "https://tieba.baidu.com/p/" + strconv.FormatUint(tid, 10),
		},
		Title: firstString(fields, 3), Summary: summary, Author: author,
		PublishedAt: unixTime(timestamp), Media: media, Tags: []string{forum + "吧"},
		Stats: domain.Stats{
			Comments: int64(firstUint(fields, 4)), Views: int64(firstUint(fields, 5)), Shares: int64(firstUint(fields, 135)),
		},
	}, nil
}

func decodePostsResponse(body []byte, ref domain.Ref) (domain.Detail, error) {
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
	item.Ref = ref
	users := decodeUsers(allBytes(data, 13))
	if author, ok := users[item.Author.ID]; ok {
		item.Author = author
	}
	posts := allBytes(data, 6)
	var detail domain.Detail
	detail.Item = item
	for index, encoded := range posts {
		post, parseErr := decodePost(encoded, ref)
		if parseErr != nil {
			continue
		}
		if author, ok := users[post.Author.ID]; ok {
			post.Author = author
		}
		if index == 0 || post.Ref.ID == ref.ParentID {
			detail.Body = post.Body
			detail.Media = appendUniqueMedia(detail.Media, post.Media...)
			if detail.Author.Name == "" {
				detail.Author = post.Author
			}
			if detail.PublishedAt.IsZero() {
				detail.PublishedAt = post.PublishedAt
			}
			continue
		}
		detail.Comments = append(detail.Comments, post)
	}
	if detail.Title == "" {
		detail.Title = "贴吧主题 " + ref.ID
	}
	return detail, nil
}

func appendUniqueMedia(existing []domain.Media, additions ...domain.Media) []domain.Media {
	seen := make(map[string]bool, len(existing)+len(additions))
	for _, media := range existing {
		seen[media.Kind+"\x00"+media.URL+"\x00"+media.PreviewURL] = true
	}
	for _, media := range additions {
		key := media.Kind + "\x00" + media.URL + "\x00" + media.PreviewURL
		if key == "\x00\x00" || seen[key] {
			continue
		}
		seen[key] = true
		existing = append(existing, media)
	}
	return existing
}

func decodePost(encoded []byte, threadRef domain.Ref) (domain.Comment, error) {
	fields, err := parseFields(encoded)
	if err != nil {
		return domain.Comment{}, err
	}
	body, media := decodeContents(allBytes(fields, 5))
	author, _ := decodeAuthor(firstBytes(fields, 23))
	if author.ID == "0" || author.ID == "" {
		author.ID = strconv.FormatUint(firstUint(fields, 19), 10)
	}
	return domain.Comment{
		Ref:    domain.Ref{Source: domain.SourceTieba, ID: strconv.FormatUint(firstUint(fields, 1), 10), ParentID: threadRef.ID, URL: threadRef.URL},
		Author: author, Body: body, PublishedAt: unixTime(firstUint(fields, 4)), Media: media,
	}, nil
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
	avatar := ""
	if portrait != "" {
		avatar = "https://himg.bdimg.com/sys/portrait/item/" + url.PathEscape(portrait)
	}
	id := strconv.FormatUint(firstUint(fields, 2), 10)
	profile := domain.ProfileRef{Source: domain.SourceTieba, ID: id}
	if name != "" {
		profile.URL = "https://tieba.baidu.com/home/main?un=" + url.QueryEscape(name)
	}
	return domain.Author{Ref: profile, ID: id, Name: name, Avatar: avatar}, nil
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
		if text := strings.TrimSpace(firstString(fields, 2)); text != "" {
			textParts = append(textParts, text)
		}
		if firstUint(fields, 1) == 5 {
			videoURL := firstString(fields, 3)
			previewURL := firstString(fields, 4)
			if videoURL != "" || previewURL != "" {
				media = append(media, domain.Media{
					Kind: "video", URL: videoURL, PreviewURL: previewURL,
					Width: int(firstUint(fields, 18)), Height: int(firstUint(fields, 19)),
					Duration: time.Duration(firstUint(fields, 13)) * time.Second,
				})
			}
			continue
		}
		imageURL := firstString(fields, 25)
		if imageURL == "" {
			imageURL = firstString(fields, 9)
		}
		if imageURL == "" {
			imageURL = firstString(fields, 8)
		}
		if imageURL == "" {
			imageURL = firstString(fields, 4)
		}
		if imageURL != "" {
			media = append(media, domain.Media{Kind: "image", URL: imageURL, PreviewURL: imageURL, Width: int(firstUint(fields, 18)), Height: int(firstUint(fields, 19))})
		}
	}
	return strings.Join(textParts, ""), media
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
