package tieba

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
)

const (
	defaultHotURL = "https://tieba.baidu.com/hottopic/browse/topicList"
	hotTopicToken = "tieba-hottopic"
)

type hotTopic struct {
	ID          int64  `json:"topic_id"`
	Name        string `json:"topic_name"`
	Description string `json:"topic_desc"`
	Abstract    string `json:"abstract"`
	Picture     string `json:"topic_pic"`
	Discussions int64  `json:"discuss_num"`
	Rank        int    `json:"idx_num"`
	CreatedAt   int64  `json:"create_time"`
	URL         string `json:"topic_url"`
}

func (p *Provider) hotTopics(ctx context.Context) (domain.Page, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.hotURL, nil)
	if err != nil {
		return domain.Page{}, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "mixsocial-tui/0.2")
	body, err := p.readResponse(req, "贴吧热议榜")
	if err != nil {
		return domain.Page{}, err
	}
	var payload struct {
		ErrorNo int    `json:"errno"`
		Error   string `json:"errmsg"`
		Data    struct {
			Topics struct {
				List []hotTopic `json:"topic_list"`
			} `json:"bang_topic"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return domain.Page{}, fmt.Errorf("解析贴吧热议榜: %w", err)
	}
	if payload.ErrorNo != 0 {
		return domain.Page{}, fmt.Errorf("读取贴吧热议榜失败 (%d): %s", payload.ErrorNo, payload.Error)
	}
	page := domain.Page{Items: make([]domain.Item, 0, len(payload.Data.Topics.List))}
	cache := make(map[string]domain.Item, len(payload.Data.Topics.List))
	for _, topic := range payload.Data.Topics.List {
		if topic.ID == 0 || strings.TrimSpace(topic.Name) == "" {
			continue
		}
		item := mapHotTopic(topic)
		page.Items = append(page.Items, item)
		cache[item.Ref.ID] = item
	}
	if len(page.Items) == 0 {
		return domain.Page{}, fmt.Errorf("贴吧热议榜为空")
	}
	p.hotMu.Lock()
	p.hotItems = cache
	p.hotMu.Unlock()
	page.Notices = []string{"贴吧热榜来自贴吧全站“热议话题”榜"}
	return page, nil
}

func mapHotTopic(topic hotTopic) domain.Item {
	summary := strings.TrimSpace(topic.Description)
	if summary == "" {
		summary = strings.TrimSpace(topic.Abstract)
	}
	id := strconv.FormatInt(topic.ID, 10)
	item := domain.Item{
		Ref:   domain.Ref{Source: domain.SourceTieba, ID: id, Token: hotTopicToken, URL: html.UnescapeString(topic.URL)},
		Title: topic.Name, Summary: summary, Author: domain.Author{Name: "贴吧热议"},
		PublishedAt: time.Unix(topic.CreatedAt, 0), Stats: domain.Stats{Comments: topic.Discussions},
		Tags: []string{"贴吧热议", fmt.Sprintf("#%d", topic.Rank)},
	}
	if topic.Picture != "" {
		item.Media = append(item.Media, domain.Media{Kind: "image", URL: topic.Picture})
	}
	return item
}

func (p *Provider) hotTopicDetail(ctx context.Context, ref domain.Ref) (domain.Detail, error) {
	p.hotMu.RLock()
	item, ok := p.hotItems[ref.ID]
	p.hotMu.RUnlock()
	if !ok {
		if _, err := p.hotTopics(ctx); err != nil {
			return domain.Detail{}, err
		}
		p.hotMu.RLock()
		item, ok = p.hotItems[ref.ID]
		p.hotMu.RUnlock()
	}
	if !ok {
		return domain.Detail{}, fmt.Errorf("贴吧热议话题 %s 已不在榜单中", ref.ID)
	}
	return domain.Detail{Item: item, Body: item.Summary}, nil
}
