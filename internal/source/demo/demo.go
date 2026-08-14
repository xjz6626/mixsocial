package demo

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
)

type Provider struct{}

func New() *Provider { return &Provider{} }

func (*Provider) ID() domain.SourceID { return domain.SourceDemo }
func (*Provider) Name() string        { return "演示数据" }
func (*Provider) Capabilities() source.Capability {
	return source.CapabilityFeed | source.CapabilitySearch | source.CapabilityDetail
}

func (*Provider) Feed(context.Context, string) (domain.Page, error) {
	return domain.Page{Items: samples()}, nil
}

func (p *Provider) Browse(ctx context.Context, channel source.Channel, cursor string) (domain.Page, error) {
	page, err := p.Feed(ctx, cursor)
	if err != nil {
		return page, err
	}
	switch channel {
	case source.ChannelRecommend:
		return page, nil
	case source.ChannelHot:
		page.Notices = append(page.Notices, "演示热榜")
		return page, nil
	case source.ChannelFollowing:
		page.Items = page.Items[:1]
		page.Notices = append(page.Notices, "演示关注流")
		return page, nil
	default:
		return domain.Page{}, fmt.Errorf("unknown demo channel %q", channel)
	}
}

func (*Provider) Search(_ context.Context, query, _ string) (domain.Page, error) {
	query = strings.ToLower(strings.TrimSpace(query))
	var items []domain.Item
	for _, item := range samples() {
		if query == "" || strings.Contains(strings.ToLower(item.Title+" "+item.Summary), query) {
			items = append(items, item)
		}
	}
	return domain.Page{Items: items}, nil
}

func (*Provider) Detail(_ context.Context, ref domain.Ref) (domain.Detail, error) {
	for _, item := range samples() {
		if item.Ref.ID == ref.ID {
			return domain.Detail{Item: item, Body: item.Summary + "\n\n这是离线演示条目，用来检查键盘操作、布局与详情页。"}, nil
		}
	}
	return domain.Detail{}, fmt.Errorf("demo item %q not found", ref.ID)
}

func samples() []domain.Item {
	now := time.Now()
	return []domain.Item{
		{
			Ref: domain.Ref{Source: domain.SourceDemo, ID: "tieba-demo"}, Title: "贴吧：Go TUI 项目交流帖",
			Summary: "把贴吧主题和楼层映射成统一条目与评论。", Author: domain.Author{Name: "gopher"},
			PublishedAt: now.Add(-20 * time.Minute), Stats: domain.Stats{Views: 862, Comments: 31}, Tags: []string{"贴吧样例"},
		},
		{
			Ref: domain.Ref{Source: domain.SourceDemo, ID: "xhs-demo"}, Title: "小红书：终端信息流的一天",
			Summary: "浏览器 sidecar 负责登录和签名，TUI 只消费本地 HTTP API。", Author: domain.Author{Name: "terminalist"},
			PublishedAt: now.Add(-45 * time.Minute), Stats: domain.Stats{Likes: 128, Comments: 12, Favorites: 46}, Tags: []string{"小红书样例"},
		},
	}
}
