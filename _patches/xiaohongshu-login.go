// Derived from github.com/xpzouying/xiaohongshu-mcp/xiaohongshu/login.go.
// (Apache-2.0). FetchQrcodeImage is adjusted to wait for the login elements
// instead of the page load event, which the continuously loading explore page
// does not reliably emit.
package xiaohongshu

import (
	"context"
	"encoding/json"
	"time"

	"github.com/go-rod/rod"
	"github.com/pkg/errors"
)

type LoginAction struct {
	page *rod.Page
}

func NewLogin(page *rod.Page) *LoginAction {
	return &LoginAction{page: page}
}

func (a *LoginAction) CheckLoginStatus(ctx context.Context) (bool, error) {
	pp := a.page.Context(ctx).Timeout(30 * time.Second)
	pp.MustNavigate("https://www.xiaohongshu.com/explore").MustWaitLoad()

	time.Sleep(1 * time.Second)

	exists, _, err := pp.Has(`.main-container .user .link-wrapper .channel`)
	if err != nil {
		return false, errors.Wrap(err, "check login status failed")
	}
	if !exists {
		return false, errors.Wrap(err, "login status element not found")
	}
	return true, nil
}

type CurrentUser struct {
	Nickname string `json:"nickname"`
	UserID   string `json:"userId"`
}

func (a *LoginAction) CurrentUser(ctx context.Context) (*CurrentUser, error) {
	pp := a.page.Context(ctx).Timeout(10 * time.Second)

	res, err := pp.Eval(`() => {
		const u = window.__INITIAL_STATE__ && window.__INITIAL_STATE__.user;
		const info = u && u.userInfo && u.userInfo.value !== undefined ? u.userInfo.value : (u && u.userInfo);
		if (!info || info.guest) return "";
		return JSON.stringify({nickname: info.nickname, userId: info.userId || info.user_id});
	}`)
	if err != nil {
		return nil, errors.Wrap(err, "read current user state failed")
	}

	raw := res.Value.String()
	if raw == "" {
		return nil, errors.New("current user not found in page state")
	}

	var user CurrentUser
	if err := json.Unmarshal([]byte(raw), &user); err != nil {
		return nil, errors.Wrap(err, "unmarshal current user failed")
	}
	return &user, nil
}

func (a *LoginAction) Login(ctx context.Context) error {
	pp := a.page.Context(ctx)
	pp.MustNavigate("https://www.xiaohongshu.com/explore").MustWaitLoad()

	time.Sleep(2 * time.Second)
	if exists, _, _ := pp.Has(".main-container .user .link-wrapper .channel"); exists {
		return nil
	}
	pp.MustElement(".main-container .user .link-wrapper .channel")
	return nil
}

func (a *LoginAction) FetchQrcodeImage(ctx context.Context) (string, bool, error) {
	pp := a.page.Context(ctx)
	if err := pp.Navigate("https://www.xiaohongshu.com/explore"); err != nil {
		return "", false, errors.Wrap(err, "navigate to explore failed")
	}

	// The explore page keeps network activity alive and sometimes never emits
	// the load event. The QR and signed-in marker are the actual readiness
	// conditions, so poll them directly without calling WaitLoad.
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		if exists, _, err := pp.Has(".main-container .user .link-wrapper .channel"); err == nil && exists {
			return "", true, nil
		}
		if exists, element, err := pp.Has(".login-container .qrcode-img"); err == nil && exists && element != nil {
			src, attrErr := element.Attribute("src")
			if attrErr != nil {
				return "", false, errors.Wrap(attrErr, "get qrcode src failed")
			}
			if src != nil && *src != "" {
				return *src, false, nil
			}
		}

		select {
		case <-ctx.Done():
			return "", false, errors.Wrap(ctx.Err(), "wait for qrcode element failed")
		case <-ticker.C:
		}
	}
}

func (a *LoginAction) WaitForLogin(ctx context.Context) bool {
	pp := a.page.Context(ctx)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return false
		case <-ticker.C:
			el, err := pp.Element(".main-container .user .link-wrapper .channel")
			if err == nil && el != nil {
				return true
			}
		}
	}
}
