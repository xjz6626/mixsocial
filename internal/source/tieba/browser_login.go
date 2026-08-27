//go:build !android && !ios

package tieba

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/go-rod/rod"
	"github.com/go-rod/rod/lib/launcher"
	"github.com/go-rod/rod/lib/launcher/flags"
	"github.com/go-rod/rod/lib/proto"

	"github.com/xjz6626/mixsocial/internal/source"
)

const baiduLoginURL = "https://passport.baidu.com/v2/?login"

func browserLoginCapability() source.Capability { return source.CapabilityQRCodeLogin }

type browserLoginSession struct {
	launcher *launcher.Launcher
	browser  *rod.Browser
	page     *rod.Page
	timer    *time.Timer
}

// LoginQRCode uses Baidu's official account page and keeps the same browser
// alive while the phone confirms the login. No password or private browser
// profile is read by mixsocial.
func (p *Provider) LoginQRCode(ctx context.Context) (source.LoginChallenge, error) {
	browserPath, err := resolveBrowserPath(p.browserPath)
	if err != nil {
		return source.LoginChallenge{}, err
	}
	p.closeBrowserLogin()

	launch := launcher.New().Bin(browserPath).Headless(true).Set(flags.NoSandbox)
	controlURL, err := launch.Launch()
	if err != nil {
		launch.Cleanup()
		return source.LoginChallenge{}, fmt.Errorf("启动贴吧登录浏览器: %w", err)
	}
	browser := rod.New().ControlURL(controlURL)
	if err := browser.Connect(); err != nil {
		launch.Kill()
		launch.Cleanup()
		return source.LoginChallenge{}, fmt.Errorf("连接贴吧登录浏览器: %w", err)
	}
	page, err := browser.Page(proto.TargetCreateTarget{URL: "about:blank"})
	if err != nil {
		closeRodSession(&browserLoginSession{launcher: launch, browser: browser})
		return source.LoginChallenge{}, fmt.Errorf("创建贴吧登录页: %w", err)
	}
	workPage := page.Context(ctx).Timeout(30 * time.Second)
	if err := workPage.Navigate(baiduLoginURL); err != nil {
		closeRodSession(&browserLoginSession{launcher: launch, browser: browser, page: page})
		return source.LoginChallenge{}, fmt.Errorf("打开百度官方登录页: %w", err)
	}
	if err := workPage.WaitLoad(); err != nil {
		closeRodSession(&browserLoginSession{launcher: launch, browser: browser, page: page})
		return source.LoginChallenge{}, fmt.Errorf("等待百度官方登录页: %w", err)
	}
	element, err := workPage.Element("img.tang-pass-qrcode-img")
	if err != nil {
		closeRodSession(&browserLoginSession{launcher: launch, browser: browser, page: page})
		return source.LoginChallenge{}, fmt.Errorf("百度登录页未显示二维码: %w", err)
	}
	image, err := element.Resource()
	if err != nil {
		closeRodSession(&browserLoginSession{launcher: launch, browser: browser, page: page})
		return source.LoginChallenge{}, fmt.Errorf("读取百度登录二维码: %w", err)
	}
	if len(image) == 0 {
		closeRodSession(&browserLoginSession{launcher: launch, browser: browser, page: page})
		return source.LoginChallenge{}, fmt.Errorf("百度登录页返回了空二维码")
	}

	session := &browserLoginSession{launcher: launch, browser: browser, page: page}
	session.timer = time.AfterFunc(3*time.Minute, func() {
		p.browserMu.Lock()
		if p.browserLogin == session {
			p.browserLogin = nil
			closeRodSession(session)
		}
		p.browserMu.Unlock()
	})
	p.browserMu.Lock()
	p.browserLogin = session
	p.browserMu.Unlock()
	return source.LoginChallenge{Image: image, Timeout: 3 * time.Minute}, nil
}

func (p *Provider) browserLoginStatus(ctx context.Context) (source.LoginStatus, bool, error) {
	p.browserMu.Lock()
	session := p.browserLogin
	if session == nil {
		p.browserMu.Unlock()
		return source.LoginStatus{}, false, nil
	}
	cookies, err := session.browser.Context(ctx).GetCookies()
	if err != nil {
		p.browserLogin = nil
		closeRodSession(session)
		p.browserMu.Unlock()
		return source.LoginStatus{}, true, fmt.Errorf("检查百度扫码状态: %w", err)
	}
	var bduss, stoken, bdussBFESS string
	for _, cookie := range cookies {
		switch strings.ToUpper(cookie.Name) {
		case "BDUSS":
			bduss = cookie.Value
		case "BDUSS_BFESS":
			bdussBFESS = cookie.Value
		case "STOKEN":
			stoken = cookie.Value
		}
	}
	if bduss == "" {
		bduss = bdussBFESS
	}
	if bduss == "" {
		p.browserMu.Unlock()
		return source.LoginStatus{}, true, nil
	}
	p.browserLogin = nil
	closeRodSession(session)
	p.browserMu.Unlock()

	validated, err := p.validateSession(ctx, sessionData{BDUSS: bduss, STOKEN: stoken})
	if err != nil {
		return source.LoginStatus{}, true, err
	}
	if err := p.setSession(validated); err != nil {
		return source.LoginStatus{}, true, err
	}
	return loginStatus(validated), true, nil
}

func (p *Provider) Close() error {
	p.closeBrowserLogin()
	return nil
}

func (p *Provider) closeBrowserLogin() {
	p.browserMu.Lock()
	session := p.browserLogin
	p.browserLogin = nil
	if session != nil {
		closeRodSession(session)
	}
	p.browserMu.Unlock()
}

func closeRodSession(session *browserLoginSession) {
	if session == nil {
		return
	}
	if session.timer != nil {
		session.timer.Stop()
	}
	if session.page != nil {
		_ = session.page.Close()
	}
	if session.browser != nil {
		_ = session.browser.Close()
	}
	if session.launcher != nil {
		session.launcher.Kill()
		session.launcher.Cleanup()
	}
}

func resolveBrowserPath(explicit string) (string, error) {
	if explicit = strings.TrimSpace(explicit); explicit != "" {
		path, err := exec.LookPath(explicit)
		if err != nil {
			return "", fmt.Errorf("找不到贴吧登录浏览器 %q: %w", explicit, err)
		}
		return path, nil
	}
	cacheDir, err := os.UserCacheDir()
	if err == nil {
		pattern := filepath.Join(cacheDir, "xiaohongshu-mcp", "browser", "*", "browser", "chrome")
		if runtime.GOOS == "windows" {
			pattern += ".exe"
		}
		matches, _ := filepath.Glob(pattern)
		sort.Strings(matches)
		for index := len(matches) - 1; index >= 0; index-- {
			if info, statErr := os.Stat(matches[index]); statErr == nil && !info.IsDir() {
				return matches[index], nil
			}
		}
	}
	for _, name := range []string{"google-chrome", "chromium", "chromium-browser", "chrome"} {
		if path, lookupErr := exec.LookPath(name); lookupErr == nil {
			return path, nil
		}
	}
	return "", fmt.Errorf("未找到 Chromium；请重新运行 install.sh，或设置 MIXSOCIAL_BROWSER。仍可按 B 导入 BDUSS")
}

var _ source.Authenticator = (*Provider)(nil)
