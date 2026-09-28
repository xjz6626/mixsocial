// Portions of this file are adapted and modified from github.com/JimChengLin/zhihu-tui
// under the Apache License 2.0. See NOTICE and THIRD_PARTY.md.
package zhihu

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
)

// The TUI prefetches visible details, so keep a Zhihu page deliberately small
// to avoid turning one refresh into a burst of dozens of API requests.
const defaultPageSize = 10

type Config struct {
	Client      *http.Client
	SessionPath string
	PageSize    int
	Endpoints   Endpoints
}

type Provider struct {
	api         *apiClient
	sessionPath string
	pageSize    int
	auth        authState
}

func New(config Config) *Provider {
	pageSize := config.PageSize
	if pageSize <= 0 {
		pageSize = defaultPageSize
	}
	cookies, _ := loadSession(config.SessionPath)
	return &Provider{
		api:         newAPIClient(config.Client, config.Endpoints, cookies),
		sessionPath: config.SessionPath,
		pageSize:    pageSize,
	}
}

func (*Provider) ID() domain.SourceID { return domain.SourceZhihu }

func (*Provider) Name() string { return "知乎" }

func (*Provider) Capabilities() source.Capability {
	return source.CapabilityFeed | source.CapabilitySearch | source.CapabilityDetail |
		source.CapabilityLike | source.CapabilityComment | source.CapabilityReply |
		source.CapabilityHot | source.CapabilityFollowing |
		source.CapabilityCredentialLogin | source.CapabilityQRCodeLogin
}

func (p *Provider) Close() error {
	p.closeLogin()
	p.api.close()
	return nil
}

func (p *Provider) Feed(ctx context.Context, cursor string) (domain.Page, error) {
	return p.Browse(ctx, source.ChannelRecommend, cursor)
}

func (p *Provider) Browse(ctx context.Context, channel source.Channel, cursor string) (domain.Page, error) {
	switch channel {
	case source.ChannelRecommend:
		return p.feedPage(ctx, cursor, p.api.endpoints.APIV3+"/feed/topstory/recommend", url.Values{
			"page_number": {"1"}, "limit": {strconv.Itoa(p.pageSize)}, "action": {"down"},
		})
	case source.ChannelFollowing:
		return p.feedPage(ctx, cursor, p.api.endpoints.APIV3+"/moments", url.Values{
			"limit": {strconv.Itoa(p.pageSize)},
		})
	case source.ChannelHot:
		target := p.api.endpoints.APIV4 + "/creators/rank/hot"
		params := url.Values{"domain": {"0"}, "limit": {strconv.Itoa(p.pageSize)}}
		if cursor != "" {
			var ok bool
			target, ok = p.resolvePagingURL(cursor, p.api.endpoints.APIV4)
			if !ok {
				return domain.Page{}, fmt.Errorf("知乎热榜分页游标无效")
			}
			params = nil
		}
		response, err := p.api.getJSON(ctx, target, params)
		if err != nil {
			return domain.Page{}, err
		}
		return pageFromValue(response, "", 0), nil
	default:
		return domain.Page{}, fmt.Errorf("知乎不支持%s频道", channel.Label())
	}
}

func (p *Provider) feedPage(ctx context.Context, cursor, initialURL string, params url.Values) (domain.Page, error) {
	target := initialURL
	if cursor != "" {
		var ok bool
		target, ok = p.resolvePagingURL(cursor, p.api.endpoints.APIV3)
		if !ok {
			return domain.Page{}, fmt.Errorf("知乎分页游标无效")
		}
		params = nil
	}
	response, err := p.api.getJSON(ctx, target, params)
	if err != nil {
		return domain.Page{}, err
	}
	return pageFromValue(response, cursor, 0), nil
}

func (p *Provider) safePagingURL(target string) bool {
	parsed, err := url.Parse(target)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return false
	}
	for _, base := range []string{p.api.endpoints.APIV3, p.api.endpoints.APIV4, p.api.endpoints.BaseURL} {
		allowed, parseErr := url.Parse(base)
		if parseErr == nil && strings.EqualFold(parsed.Scheme, allowed.Scheme) && strings.EqualFold(parsed.Host, allowed.Host) {
			return true
		}
	}
	return false
}

func (p *Provider) resolvePagingURL(cursor, apiBase string) (string, bool) {
	if strings.HasPrefix(cursor, "/") && !strings.HasPrefix(cursor, "/api/") {
		target := strings.TrimSuffix(apiBase, "/") + cursor
		return target, p.safePagingURL(target)
	}
	parsed, err := url.Parse(cursor)
	if err != nil {
		return "", false
	}
	if !parsed.IsAbs() {
		base, baseErr := url.Parse(strings.TrimSuffix(apiBase, "/") + "/")
		if baseErr != nil {
			return "", false
		}
		parsed = base.ResolveReference(parsed)
	}
	target := parsed.String()
	return target, p.safePagingURL(target)
}

func (p *Provider) Search(ctx context.Context, query, cursor string) (domain.Page, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return domain.Page{}, fmt.Errorf("知乎搜索词不能为空")
	}
	offset := 0
	if cursor != "" {
		parsed, err := strconv.Atoi(cursor)
		if err != nil || parsed < 0 {
			return domain.Page{}, fmt.Errorf("知乎搜索分页游标无效")
		}
		offset = parsed
	}
	response, err := p.api.getMap(ctx, p.api.endpoints.APIV4+"/search_v3", url.Values{
		"gk_version": {"gz-gaokao"}, "t": {"general"}, "q": {query}, "correction": {"1"},
		"offset": {strconv.Itoa(offset)}, "limit": {strconv.Itoa(p.pageSize)}, "filter_fields": {"lc_idx"},
		"lc_idx": {"0"}, "show_all_topics": {"0"}, "search_source": {"Normal"},
	})
	if err != nil {
		return domain.Page{}, err
	}
	page := pageFromResponse(response, cursor, offset)
	if page.HasMore {
		if parsed, parseErr := url.Parse(page.NextCursor); parseErr == nil && parsed.Query().Get("offset") != "" {
			page.NextCursor = parsed.Query().Get("offset")
		}
		if _, parseErr := strconv.Atoi(page.NextCursor); parseErr != nil {
			page.NextCursor = strconv.Itoa(offset + len(responseData(response)))
		}
	}
	return page, nil
}

func (p *Provider) Detail(ctx context.Context, ref domain.Ref) (domain.Detail, error) {
	if ref.Source != domain.SourceZhihu || strings.TrimSpace(ref.ID) == "" {
		return domain.Detail{}, fmt.Errorf("知乎内容引用无效")
	}
	kind := normalizedKind(ref.Token)
	if kind == "" {
		kind = kindFromURL(ref.URL)
	}
	if kind == "" {
		kind = "answer"
	}
	raw, err := p.fetchContent(ctx, kind, ref.ID)
	if err != nil {
		return domain.Detail{}, err
	}
	raw["type"] = kind
	detail := detailFromTarget(raw)
	detail.Ref = ref
	detail.Ref.Token = kind
	if detail.Ref.URL == "" {
		detail.Ref.URL = contentURL(kind, ref.ID, ref.ParentID)
	}
	comments, commentsErr := p.fetchComments(ctx, kind, ref.ID, "")
	if commentsErr == nil {
		detail.Comments = comments.Comments
		detail.NextCursor = comments.NextCursor
		detail.HasMore = comments.HasMore
	}
	if detail.Title == "" {
		detail.Title = ref.ID
	}
	return detail, nil
}

func (p *Provider) fetchContent(ctx context.Context, kind, id string) (map[string]any, error) {
	escaped := url.PathEscape(id)
	switch kind {
	case "answer":
		return p.api.getMap(ctx, p.api.endpoints.APIV4+"/answers/"+escaped, url.Values{
			"include": {"content,voteup_count,comment_count,created_time,updated_time,author,question,favlists_count,thanks_count"},
		})
	case "article":
		return p.api.getMap(ctx, p.api.endpoints.ZhuanlanAPI+"/articles/"+escaped, nil)
	case "pin":
		return p.api.getMap(ctx, p.api.endpoints.APIV4+"/pins/"+escaped, nil)
	case "question":
		response, err := p.api.getMap(ctx, p.api.endpoints.APIV4+"/questions/"+escaped+"/answers", url.Values{
			"include": {"data[*].content,voteup_count,comment_count,created_time,updated_time,author,question"},
			"offset":  {"0"}, "limit": {"5"}, "sort_by": {"default"},
		})
		if err != nil {
			return nil, err
		}
		answers := sliceValue(response["data"])
		if len(answers) == 0 {
			return map[string]any{"id": id, "type": "question", "title": "知乎问题"}, nil
		}
		first := mapValue(answers[0])
		question := cloneMap(mapValue(first["question"]))
		if len(question) == 0 {
			question = map[string]any{"id": id}
		}
		question["type"] = "question"
		question["top_answers"] = answers
		return question, nil
	default:
		return nil, fmt.Errorf("暂不支持知乎内容类型 %q", kind)
	}
}

func (p *Provider) fetchComments(ctx context.Context, kind, id, cursor string) (domain.CommentPage, error) {
	if kind != "answer" && kind != "article" && kind != "pin" && kind != "question" {
		return domain.CommentPage{}, fmt.Errorf("知乎内容类型 %q 不支持评论", kind)
	}
	response, err := p.api.getMap(ctx, p.api.endpoints.APIV4+"/comment_v5/"+kind+"s/"+url.PathEscape(id)+"/root_comment", url.Values{
		"offset": {cursor}, "limit": {strconv.Itoa(p.pageSize)}, "order_by": {"score"},
	})
	if err != nil {
		return domain.CommentPage{}, err
	}
	return commentPageFromResponse(response, kind, id, cursor), nil
}

func (p *Provider) Like(ctx context.Context, ref domain.Ref, value bool) error {
	kind := normalizedKind(ref.Token)
	if kind == "question" || kind == "" {
		return fmt.Errorf("知乎问题使用关注操作，不支持点赞")
	}
	accepted := map[int]bool{http.StatusOK: true, http.StatusCreated: true, http.StatusNoContent: true}
	var (
		result map[string]any
		err    error
	)
	switch kind {
	case "answer":
		voteType := "neutral"
		if value {
			voteType = "up"
		}
		result, err = p.api.mutateJSON(ctx, http.MethodPost, p.api.endpoints.APIV4+"/answers/"+url.PathEscape(ref.ID)+"/voters", map[string]any{"type": voteType}, accepted)
	case "article":
		voting := 0
		if value {
			voting = 1
		}
		result, err = p.api.mutateJSON(ctx, http.MethodPost, p.api.endpoints.APIV4+"/articles/"+url.PathEscape(ref.ID)+"/voters", map[string]any{"voting": voting}, accepted)
	case "pin":
		method := http.MethodPost
		if !value {
			method = http.MethodDelete
		}
		_, err = p.api.mutateJSON(ctx, method, p.api.endpoints.APIV4+"/pins/"+url.PathEscape(ref.ID)+"/likers", nil, accepted)
	default:
		return fmt.Errorf("知乎内容类型 %q 不支持点赞", kind)
	}
	if err != nil {
		return err
	}
	if actual, present := result["voting"]; present {
		want := int64(0)
		if value {
			want = 1
		}
		if int64Value(actual) != want {
			return fmt.Errorf("知乎没有确认点赞状态")
		}
	}
	return nil
}

func (*Provider) Favorite(context.Context, domain.Ref, bool) error {
	return fmt.Errorf("知乎适配器尚不支持选择收藏夹，未执行收藏操作")
}

func (p *Provider) Comment(ctx context.Context, ref domain.Ref, body string) error {
	return p.writeComment(ctx, ref, "", body)
}

func (p *Provider) Reply(ctx context.Context, ref domain.Ref, comment domain.Ref, body string) error {
	if comment.Source != domain.SourceZhihu || comment.ID == "" {
		return fmt.Errorf("知乎回复目标无效")
	}
	return p.writeComment(ctx, ref, comment.ID, body)
}

func (p *Provider) writeComment(ctx context.Context, ref domain.Ref, replyID, body string) error {
	kind := normalizedKind(ref.Token)
	if kind == "" || ref.ID == "" {
		return fmt.Errorf("知乎评论目标无效")
	}
	body = strings.TrimSpace(body)
	if body == "" {
		return fmt.Errorf("知乎评论内容不能为空")
	}
	payload := map[string]any{
		"content": body, "selected_settings": []string{}, "unfriendly_check": "strict",
	}
	if replyID != "" {
		payload["reply_comment_id"] = replyID
	}
	_, err := p.api.mutateJSON(ctx, http.MethodPost, p.api.endpoints.APIV4+"/comment_v5/"+kind+"s/"+url.PathEscape(ref.ID)+"/comment", payload,
		map[int]bool{http.StatusOK: true, http.StatusCreated: true})
	return err
}

func cloneMap(input map[string]any) map[string]any {
	output := make(map[string]any, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}
