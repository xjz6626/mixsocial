package tieba

import (
	"context"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/xjz6626/mixsocial/internal/domain"
)

// Protocol fields checked against aiotieba's ProfileReqIdl/ProfileResIdl,
// User and PostInfoList definitions. No private user fields are exported.
type ProfileStat struct {
	Name  string `json:"name"`
	Count string `json:"count"`
}

type ProfilePage struct {
	Ref         domain.ProfileRef `json:"ref"`
	Name        string            `json:"name"`
	Avatar      string            `json:"avatar,omitempty"`
	Description string            `json:"description,omitempty"`
	Location    string            `json:"location,omitempty"`
	Stats       []ProfileStat     `json:"stats,omitempty"`
	Items       []domain.Item     `json:"items"`
	NextCursor  string            `json:"nextCursor,omitempty"`
	HasMore     bool              `json:"hasMore"`
}

func (p *Provider) Profile(ctx context.Context, ref domain.ProfileRef, cursor string) (ProfilePage, error) {
	uid, err := strconv.ParseUint(ref.ID, 10, 63)
	if err != nil || uid == 0 || ref.Source != domain.SourceTieba {
		return ProfilePage{}, fmt.Errorf("无效的贴吧用户编号")
	}
	pn := 1
	if cursor != "" {
		pn, err = strconv.Atoi(cursor)
		if err != nil || pn < 1 || pn > 100000 {
			return ProfilePage{}, fmt.Errorf("无效的用户主页页码")
		}
	}
	var data []byte
	data = appendUint(data, 1, uid)
	data = appendUint(data, 2, 1)
	data = appendUint(data, 6, uint64(pn))
	data = appendBytes(data, 9, encodeCommon())
	endpoint := p.profileURL
	if endpoint == "" {
		endpoint = "https://tiebac.baidu.com/c/u/user/profile?cmd=303012"
	}
	body, err := p.postProto(ctx, endpoint, appendBytes(nil, 1, data))
	if err != nil {
		return ProfilePage{}, err
	}
	return decodeProfileResponse(body, ref, pn)
}

func decodeProfileResponse(body []byte, ref domain.ProfileRef, page int) (ProfilePage, error) {
	root, err := parseFields(body)
	if err != nil {
		return ProfilePage{}, fmt.Errorf("解析贴吧主页响应失败: %w", err)
	}
	if err = responseError(root); err != nil {
		return ProfilePage{}, err
	}
	data, err := parseFields(firstBytes(root, 2))
	if err != nil {
		return ProfilePage{}, fmt.Errorf("解析贴吧主页数据失败: %w", err)
	}
	user, err := parseFields(firstBytes(data, 1))
	if err != nil || firstUint(user, 2) == 0 {
		return ProfilePage{}, fmt.Errorf("贴吧主页没有返回可用用户资料")
	}
	if strconv.FormatUint(firstUint(user, 2), 10) != ref.ID {
		return ProfilePage{}, fmt.Errorf("贴吧主页返回的用户与请求不一致")
	}
	author, _ := decodeAuthor(firstBytes(data, 1))
	if username := firstString(user, 3); username != "" {
		ref.URL = "https://tieba.baidu.com/home/main?un=" + url.QueryEscape(username)
	}
	author.Ref = ref
	result := ProfilePage{Ref: ref, Name: author.Name, Avatar: author.Avatar,
		Description: firstString(user, 34), Location: firstString(user, 127), Items: []domain.Item{}}
	for _, stat := range []struct {
		name  string
		field int
	}{{"帖子", 37}, {"粉丝", 30}, {"关注", 31}, {"关注吧", 33}} {
		result.Stats = append(result.Stats, ProfileStat{Name: stat.name, Count: strconv.FormatUint(firstUint(user, stat.field), 10)})
	}
	seen := map[string]bool{}
	posts := allBytes(data, 4)
	for _, encoded := range posts {
		fields, parseErr := parseFields(encoded)
		if parseErr != nil {
			continue
		}
		tid := firstUint(fields, 2)
		if tid == 0 {
			continue
		}
		id := strconv.FormatUint(tid, 10)
		if seen[id] {
			continue
		}
		seen[id] = true
		text, media := decodeContents(allBytes(fields, 49))
		if text == "" {
			var parts []string
			for _, raw := range allBytes(fields, 8) {
				content, contentErr := parseFields(raw)
				if contentErr != nil {
					continue
				}
				part, _ := decodeContents(allBytes(content, 1))
				if part != "" {
					parts = append(parts, part)
				}
			}
			text = strings.Join(parts, "\n")
		}
		title := firstString(fields, 7)
		if title == "" {
			title = "贴吧帖子 " + id
		}
		item := domain.Item{Ref: domain.Ref{Source: domain.SourceTieba, ID: id, URL: "https://tieba.baidu.com/p/" + id},
			Title: title, Summary: text, Author: author, Media: media,
			PublishedAt: unixTime(firstUint(fields, 5)), Stats: domain.Stats{Comments: int64(firstUint(fields, 17))}}
		if forum := firstString(fields, 6); forum != "" { item.Tags = []string{forum + "吧"} }
		result.Items = append(result.Items, item)
	}
	// This endpoint exposes no total-page field. Stop on an empty page; callers
	// additionally stop if a repeated page produces no new thread IDs.
	result.HasMore = len(result.Items) > 0 && page < 100000
	if result.HasMore {
		result.NextCursor = strconv.Itoa(page + 1)
	}
	return result, nil
}
