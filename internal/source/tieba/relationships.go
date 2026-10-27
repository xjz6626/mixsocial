package tieba

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/xjz6626/mixsocial/internal/domain"
)

// Protocol paths and form fields checked against aiotieba's follow_user,
// unfollow_user, follow_forum and unfollow_forum implementations. Writes are
// sent once; an uncertain result must be resolved with a separate state read.
func (p *Provider) Follow(ctx context.Context, ref domain.ProfileRef, value bool) error {
	session, err := p.relationshipSession()
	if err != nil {
		return err
	}
	if ref.Source != domain.SourceTieba || ref.ID == session.UserID {
		return fmt.Errorf("无效的贴吧关注对象")
	}
	profile, err := p.Profile(ctx, ref, "")
	if err != nil {
		return err
	}
	if profile.Ref.Token == "" {
		return fmt.Errorf("贴吧作者资料缺少 portrait，未发送关注请求")
	}
	if profile.Following != nil && *profile.Following == value {
		return nil
	}
	action := "follow"
	if !value {
		action = "unfollow"
	}
	if err := p.writeRelationship(ctx, "/c/c/user/"+action, "portrait", profile.Ref.Token, session); err != nil {
		return err
	}
	actual, err := p.Following(ctx, ref)
	if err != nil {
		return fmt.Errorf("关注请求已提交，但状态未能确认，请刷新核对: %w", err)
	}
	if actual != value {
		return fmt.Errorf("贴吧尚未确认关注状态，请刷新核对；未重复提交")
	}
	return nil
}

func (p *Provider) Following(ctx context.Context, ref domain.ProfileRef) (bool, error) {
	if _, err := p.relationshipSession(); err != nil {
		return false, err
	}
	profile, err := p.Profile(ctx, ref, "")
	if err != nil {
		return false, err
	}
	if profile.Following == nil {
		return false, fmt.Errorf("贴吧未返回可确认的作者关注状态")
	}
	return *profile.Following, nil
}

func (p *Provider) FollowForum(ctx context.Context, forum string, value bool) error {
	session, err := p.relationshipSession()
	if err != nil {
		return err
	}
	forum = normalizeRelationshipForum(forum)
	if forum == "" {
		return fmt.Errorf("贴吧名称不能为空")
	}
	current, err := p.ForumFollowing(ctx, forum)
	if err != nil {
		return err
	}
	if current == value {
		return nil
	}
	fid, err := p.resolveForumID(ctx, forum)
	if err != nil {
		return err
	}
	action := "like"
	if !value {
		action = "unfavolike"
	}
	if err := p.writeRelationship(ctx, "/c/c/forum/"+action, "fid", fid, session); err != nil {
		return err
	}
	actual, err := p.ForumFollowing(ctx, forum)
	if err != nil {
		return fmt.Errorf("吧关注请求已提交，但状态未能确认，请刷新核对: %w", err)
	}
	if actual != value {
		return fmt.Errorf("贴吧尚未确认吧关注状态，请刷新核对；未重复提交")
	}
	return nil
}

func (p *Provider) ForumFollowing(ctx context.Context, forum string) (bool, error) {
	forum = normalizeRelationshipForum(forum)
	if forum == "" {
		return false, fmt.Errorf("贴吧名称不能为空")
	}
	forums, err := p.FollowingForums(ctx)
	if err != nil {
		return false, err
	}
	for _, name := range forums {
		if strings.EqualFold(normalizeRelationshipForum(name), forum) {
			return true, nil
		}
	}
	return false, nil
}

func normalizeRelationshipForum(forum string) string {
	return strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(forum), "吧"))
}

func (p *Provider) relationshipSession() (sessionData, error) {
	session, err := p.sessionSnapshot()
	if err != nil {
		return sessionData{}, err
	}
	if session.BDUSS == "" || session.TBS == "" {
		return sessionData{}, fmt.Errorf("贴吧关注操作需要有效登录")
	}
	return session, nil
}

func (p *Provider) writeRelationship(ctx context.Context, path, key, target string, session sessionData) error {
	response, err := p.postSignedFormFor(ctx, "https://tiebac.baidu.com"+path, []formValue{
		{key: "BDUSS", value: session.BDUSS}, {key: key, value: target}, {key: "tbs", value: session.TBS},
	}, "贴吧关注")
	if err != nil {
		return err
	}
	var result struct {
		Code    json.RawMessage `json:"error_code"`
		Message string          `json:"error_msg"`
		Error   *struct {
			Code    json.RawMessage `json:"errno"`
			Message string          `json:"errmsg"`
		} `json:"error"`
	}
	if err := json.Unmarshal(response, &result); err != nil {
		return fmt.Errorf("贴吧关注响应无效，请刷新核对")
	}
	if rawScalar(result.Code) != "0" {
		return fmt.Errorf("贴吧关注失败 (%s): %s", rawScalar(result.Code), fallback(result.Message, "未确认成功"))
	}
	if result.Error != nil && rawScalar(result.Error.Code) != "0" {
		return fmt.Errorf("贴吧关注失败 (%s): %s", rawScalar(result.Error.Code), result.Error.Message)
	}
	return nil
}

func (p *Provider) resolveForumID(ctx context.Context, forum string) (string, error) {
	target := "https://tieba.baidu.com/f/commit/share/fnameShareApi?" + url.Values{"fname": {forum}, "ie": {"utf-8"}}.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return "", err
	}
	response, err := p.readResponse(request, "贴吧编号查询")
	if err != nil {
		return "", err
	}
	var result struct {
		Code json.RawMessage `json:"no"`
		Data struct {
			ID   json.RawMessage `json:"fid"`
			Name string          `json:"fname"`
		} `json:"data"`
	}
	if json.Unmarshal(response, &result) != nil || rawScalar(result.Code) != "0" {
		return "", fmt.Errorf("无法确认贴吧编号，未发送关注请求")
	}
	fid := rawScalar(result.Data.ID)
	if id, err := strconv.ParseUint(fid, 10, 63); err != nil || id == 0 {
		return "", fmt.Errorf("贴吧编号无效，未发送关注请求")
	}
	if result.Data.Name != "" && !strings.EqualFold(normalizeRelationshipForum(result.Data.Name), forum) {
		return "", fmt.Errorf("贴吧编号查询返回了其他贴吧，未发送关注请求")
	}
	return fid, nil
}
