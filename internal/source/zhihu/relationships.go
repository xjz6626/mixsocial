package zhihu

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/xjz6626/mixsocial/internal/domain"
)

// The member followers route uses POST/DELETE, with the existing cookie and
// XSRF headers. Confirm the target and state through the member resource.
func (p *Provider) Following(ctx context.Context, ref domain.ProfileRef) (bool, error) {
	_, state, err := p.followingMember(ctx, ref)
	return state, err
}

func (p *Provider) followingMember(ctx context.Context, ref domain.ProfileRef) (string, bool, error) {
	if ref.Source != domain.SourceZhihu || strings.TrimSpace(ref.ID) == "" || strings.Trim(ref.ID, "0") == "" {
		return "", false, fmt.Errorf("无效的知乎作者引用")
	}
	if !hasRequiredCookies(p.api.cookieSnapshot()) {
		return "", false, loginError{message: "知乎关注操作需要有效登录"}
	}
	token := strings.TrimSpace(firstNonEmpty(ref.Token, ref.ID))
	if strings.ContainsAny(token, "/?#%\\ \t\r\n") {
		return "", false, fmt.Errorf("无效的知乎作者编号")
	}
	member, err := p.api.getMap(ctx, p.api.endpoints.APIV4+"/members/"+url.PathEscape(token), url.Values{"include": {"is_following"}})
	if err != nil {
		return "", false, err
	}
	id, slug := stringValue(member["id"]), stringValue(member["url_token"])
	if (id != ref.ID && slug != ref.ID) || (ref.Token != "" && slug != "" && slug != ref.Token) {
		return "", false, fmt.Errorf("知乎返回的作者与关注目标不一致")
	}
	state, ok := member["is_following"].(bool)
	if !ok {
		return "", false, fmt.Errorf("知乎未返回可确认的作者关注状态")
	}
	return token, state, nil
}

func (p *Provider) Follow(ctx context.Context, ref domain.ProfileRef, value bool) error {
	token, current, err := p.followingMember(ctx, ref)
	if err != nil {
		return err
	}
	if current == value {
		return nil
	}
	method := http.MethodPost
	if !value {
		method = http.MethodDelete
	}
	response, err := p.api.mutateJSON(ctx, method, p.api.endpoints.APIV4+"/members/"+url.PathEscape(token)+"/followers", nil,
		map[int]bool{http.StatusOK: true, http.StatusCreated: true, http.StatusNoContent: true})
	if err != nil {
		return err
	}
	if response["error"] != nil {
		return fmt.Errorf("知乎拒绝了关注操作，请刷新核对")
	}
	if code, ok := response["code"]; ok && stringValue(code) != "0" {
		return fmt.Errorf("知乎关注操作未确认成功")
	}
	for _, key := range []string{"is_following", "followed"} {
		if actual, present := response[key]; present {
			if actual != value {
				return fmt.Errorf("知乎返回的关注状态与请求不一致，请刷新核对")
			}
		}
	}
	actual, err := p.Following(ctx, ref)
	if err != nil {
		return fmt.Errorf("关注请求已提交，但状态未能确认，请刷新核对: %w", err)
	}
	if actual != value {
		return fmt.Errorf("知乎尚未确认关注状态，请刷新核对；未重复提交")
	}
	return nil
}
