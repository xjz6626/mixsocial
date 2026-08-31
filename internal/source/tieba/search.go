package tieba

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
)

const defaultSearchURL = "https://tieba.baidu.com/mo/q/search/thread"

// The mobile hybrid search endpoint is also used by Tieba's public web search.
// It returns ordinary JSON and does not require an account for read-only queries.
func (p *Provider) searchThreads(ctx context.Context, query, cursor string) (domain.Page, error) {
	return p.searchThreadsInForum(ctx, "", query, cursor)
}

// SearchForumThreads uses the same public Hybrid endpoint as global search,
// narrowed by fname. It does not require account cookies.
func (p *Provider) SearchForumThreads(ctx context.Context, forum, query, cursor string) (domain.Page, error) {
	forum = strings.TrimSpace(strings.TrimSuffix(forum, "吧"))
	if forum == "" {
		return domain.Page{}, fmt.Errorf("请输入贴吧吧名")
	}
	return p.searchThreadsInForum(ctx, forum, query, cursor)
}

func (p *Provider) searchThreadsInForum(ctx context.Context, forum, query, cursor string) (domain.Page, error) {
	keyword := strings.TrimSpace(query)
	if keyword == "" {
		return domain.Page{}, fmt.Errorf("请输入搜索词")
	}
	pageNumber := positiveInt(cursor, 1)
	endpoint, err := url.Parse(p.searchURL)
	if err != nil {
		return domain.Page{}, fmt.Errorf("解析贴吧搜索地址: %w", err)
	}
	parameters := endpoint.Query()
	parameters.Set("word", keyword)
	parameters.Set("pn", strconv.Itoa(pageNumber))
	parameters.Set("st", "1")
	parameters.Set("tt", "1")
	parameters.Set("rn", strconv.Itoa(p.pageSize))
	parameters.Set("ct", "1")
	parameters.Set("is_use_zonghe", "1")
	parameters.Set("cv", "99.9.101")
	if forum != "" {
		parameters.Set("fname", forum)
		parameters.Set("ct", "2")
		parameters.Del("is_use_zonghe")
	}
	endpoint.RawQuery = parameters.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return domain.Page{}, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36")
	req.Header.Set("Referer", "https://tieba.baidu.com/mo/q/hybrid/search?keyword="+url.QueryEscape(keyword))

	body, err := p.readResponse(req, "贴吧全站搜索")
	if err != nil {
		return domain.Page{}, err
	}
	return decodeSearchResponse(body, pageNumber)
}

type searchResponse struct {
	Code  int    `json:"no"`
	Error string `json:"error"`
	Data  struct {
		HasMore any             `json:"has_more"`
		Posts   []searchPostRaw `json:"post_list"`
	} `json:"data"`
}

type searchPostRaw struct {
	ThreadID    json.RawMessage `json:"tid"`
	PostID      json.RawMessage `json:"pid"`
	Title       string          `json:"title"`
	Content     string          `json:"content"`
	PublishedAt json.RawMessage `json:"time"`
	ModifiedAt  json.RawMessage `json:"modified_time"`
	Replies     json.RawMessage `json:"post_num"`
	Likes       json.RawMessage `json:"like_num"`
	Shares      json.RawMessage `json:"share_num"`
	ForumName   string          `json:"forum_name"`
	URL         string          `json:"pb_url"`
	User        struct {
		ID       json.RawMessage `json:"user_id"`
		Name     string          `json:"user_name"`
		Nickname string          `json:"show_nickname"`
		Portrait string          `json:"portrait"`
	} `json:"user"`
	Media []struct {
		Type     string          `json:"type"`
		Width    json.RawMessage `json:"width"`
		Height   json.RawMessage `json:"height"`
		WaterPic string          `json:"water_pic"`
		SmallPic string          `json:"small_pic"`
		BigPic   string          `json:"big_pic"`
		Source   string          `json:"src"`
		Video    string          `json:"vsrc"`
		VideoHD  string          `json:"vhsrc"`
		VideoPic string          `json:"vpic"`
	} `json:"media"`
}

func decodeSearchResponse(body []byte, pageNumber int) (domain.Page, error) {
	var payload searchResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		return domain.Page{}, fmt.Errorf("解析贴吧搜索响应: %w", err)
	}
	if payload.Code != 0 {
		return domain.Page{}, fmt.Errorf("贴吧搜索失败 (%d): %s", payload.Code, fallback(payload.Error, "未知错误"))
	}
	page := domain.Page{HasMore: truthy(payload.Data.HasMore)}
	if page.HasMore {
		page.NextCursor = strconv.Itoa(pageNumber + 1)
	}
	for _, raw := range payload.Data.Posts {
		item := raw.searchItem()
		if item.Ref.ID != "" && (item.Title != "" || item.Summary != "") {
			page.Items = append(page.Items, item)
		}
	}
	return page, nil
}

func (raw searchPostRaw) searchItem() domain.Item {
	threadID := rawScalar(raw.ThreadID)
	postID := rawScalar(raw.PostID)
	userID := rawScalar(raw.User.ID)
	name := strings.TrimSpace(raw.User.Nickname)
	if name == "" {
		name = strings.TrimSpace(raw.User.Name)
	}
	profileURL := ""
	if raw.User.Name != "" {
		profileURL = "https://tieba.baidu.com/home/main?un=" + url.QueryEscape(raw.User.Name)
	}
	threadURL := strings.TrimSpace(raw.URL)
	if threadURL == "" && threadID != "" {
		threadURL = "https://tieba.baidu.com/p/" + threadID
	}
	item := domain.Item{
		Ref:   domain.Ref{Source: domain.SourceTieba, ID: threadID, ParentID: postID, URL: threadURL},
		Title: strings.TrimSpace(raw.Title), Summary: strings.TrimSpace(raw.Content),
		Author: domain.Author{
			Ref: domain.ProfileRef{Source: domain.SourceTieba, ID: userID, URL: profileURL},
			ID:  userID, Name: fallback(name, "未知用户"), Avatar: tiebaAvatarURL(raw.User.Portrait),
		},
		Stats: domain.Stats{
			Likes: rawInt64(raw.Likes), Comments: rawInt64(raw.Replies), Shares: rawInt64(raw.Shares),
		},
	}
	if raw.ForumName != "" {
		item.Tags = []string{raw.ForumName + "吧"}
	}
	timestamp := rawInt64(raw.ModifiedAt)
	if timestamp == 0 {
		timestamp = rawInt64(raw.PublishedAt)
	}
	if timestamp > 0 {
		item.PublishedAt = time.Unix(timestamp, 0)
	}
	for _, media := range raw.Media {
		kind := "image"
		mediaURL := firstNonEmpty(media.BigPic, media.Source, media.VideoHD, media.Video)
		previewURL := firstNonEmpty(media.SmallPic, media.WaterPic, media.VideoPic, mediaURL)
		if strings.Contains(strings.ToLower(media.Type), "video") || media.Video != "" || media.VideoHD != "" {
			kind = "video"
		}
		if mediaURL == "" && previewURL == "" {
			continue
		}
		item.Media = append(item.Media, domain.Media{
			Kind: kind, URL: mediaURL, PreviewURL: previewURL,
			Width: int(rawInt64(media.Width)), Height: int(rawInt64(media.Height)),
		})
	}
	return item
}

func rawInt64(raw json.RawMessage) int64 {
	value := rawScalar(raw)
	number, _ := strconv.ParseInt(value, 10, 64)
	return number
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
