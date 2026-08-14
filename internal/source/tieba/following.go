package tieba

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

func (p *Provider) followedForumNames(ctx context.Context) ([]string, error) {
	session, err := p.sessionSnapshot()
	if err != nil {
		return nil, err
	}
	if session.BDUSS == "" {
		return nil, fmt.Errorf("贴吧尚未登录")
	}
	values := url.Values{
		"tbs":       []string{session.TBS},
		"sort_type": []string{"3"},
		"call_from": []string{"3"},
		"page_no":   []string{"1"},
		"res_num":   []string{"200"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.followURL, strings.NewReader(values.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Subapp-Type", "hybrid")
	req.Header.Set("User-Agent", "mixsocial-tui/0.2")
	cookies := "BDUSS=" + session.BDUSS
	if session.STOKEN != "" {
		cookies += "; STOKEN=" + session.STOKEN
	}
	req.Header.Set("Cookie", cookies)
	body, err := p.readResponse(req, "贴吧关注列表")
	if err != nil {
		return nil, err
	}
	var payload struct {
		ErrorCode json.RawMessage `json:"error_code"`
		ErrorMsg  string          `json:"error_msg"`
		Forums    []struct {
			Name string `json:"forum_name"`
		} `json:"like_forum"`
		HasMore any `json:"like_forum_has_more"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, fmt.Errorf("解析贴吧关注列表: %w", err)
	}
	if code := rawScalar(payload.ErrorCode); code != "" && code != "0" {
		return nil, fmt.Errorf("读取贴吧关注列表失败 (%s): %s", code, fallback(payload.ErrorMsg, "会话可能已失效"))
	}
	names := make([]string, 0, len(payload.Forums))
	seen := make(map[string]struct{}, len(payload.Forums))
	for _, forum := range payload.Forums {
		name := strings.TrimSpace(forum.Name)
		if name == "" {
			continue
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		names = append(names, name)
	}
	if len(names) == 0 && truthy(payload.HasMore) {
		return nil, fmt.Errorf("贴吧返回了空的关注列表")
	}
	return names, nil
}

func (p *Provider) readResponse(req *http.Request, operation string) ([]byte, error) {
	res, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s请求失败: %w", operation, err)
	}
	defer res.Body.Close()
	body, err := readLimitedBody(res)
	if err != nil {
		return nil, fmt.Errorf("读取%s响应: %w", operation, err)
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, fmt.Errorf("%s HTTP %d: %s", operation, res.StatusCode, strings.TrimSpace(string(body)))
	}
	return body, nil
}

func readLimitedBody(response *http.Response) ([]byte, error) {
	return io.ReadAll(io.LimitReader(response.Body, 8<<20))
}

func truthy(value any) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case float64:
		return typed != 0
	case string:
		result, _ := strconv.ParseBool(typed)
		if result {
			return true
		}
		number, _ := strconv.Atoi(typed)
		return number != 0
	default:
		return false
	}
}
