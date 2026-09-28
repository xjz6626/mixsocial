// Portions of this file are adapted and modified from github.com/JimChengLin/zhihu-tui
// under the Apache License 2.0. See NOTICE and THIRD_PARTY.md.
package zhihu

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"github.com/xjz6626/mixsocial/internal/source"
)

var requiredCookies = []string{"_xsrf", "d_c0", "z_c0"}

type sessionData struct {
	Cookies map[string]string `json:"cookies"`
}

type qrLoginSession struct {
	client    *http.Client
	jar       http.CookieJar
	token     string
	expiresAt time.Time
}

type authState struct {
	mu sync.Mutex
	qr *qrLoginSession
}

func parseCookieString(raw string) map[string]string {
	cookies := make(map[string]string)
	for _, item := range strings.Split(raw, ";") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		name, value, ok := strings.Cut(item, "=")
		name = strings.TrimSpace(name)
		if ok && name != "" {
			cookies[name] = strings.TrimSpace(value)
		}
	}
	return cookies
}

func hasRequiredCookies(cookies map[string]string) bool {
	for _, name := range requiredCookies {
		if strings.TrimSpace(cookies[name]) == "" {
			return false
		}
	}
	return true
}

func missingRequiredCookies(cookies map[string]string) []string {
	var missing []string
	for _, name := range requiredCookies {
		if strings.TrimSpace(cookies[name]) == "" {
			missing = append(missing, name)
		}
	}
	return missing
}

func loadSession(path string) (map[string]string, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("读取知乎会话: %w", err)
	}
	var session sessionData
	if err := json.Unmarshal(data, &session); err != nil {
		return nil, fmt.Errorf("解析知乎会话: %w", err)
	}
	if !hasRequiredCookies(session.Cookies) {
		return nil, fmt.Errorf("知乎会话缺少 %s", strings.Join(missingRequiredCookies(session.Cookies), "、"))
	}
	return session.Cookies, nil
}

func saveSession(path string, cookies map[string]string) error {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("创建知乎会话目录: %w", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return fmt.Errorf("设置知乎会话目录权限: %w", err)
	}
	data, err := json.MarshalIndent(sessionData{Cookies: cookies}, "", "  ")
	if err != nil {
		return fmt.Errorf("编码知乎会话: %w", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("保存知乎会话: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("设置知乎会话权限: %w", err)
	}
	return nil
}

func (p *Provider) LoginWithCredential(ctx context.Context, credential string) (source.LoginStatus, error) {
	cookies := parseCookieString(credential)
	if !hasRequiredCookies(cookies) {
		return source.LoginStatus{}, fmt.Errorf("Cookie 缺少 %s", strings.Join(missingRequiredCookies(cookies), "、"))
	}
	status, err := p.validateCookies(ctx, cookies)
	if err != nil {
		return source.LoginStatus{}, err
	}
	if err := saveSession(p.sessionPath, cookies); err != nil {
		return source.LoginStatus{}, err
	}
	p.api.setCookies(cookies)
	p.closeLogin()
	return status, nil
}

func (p *Provider) LoginQRCode(ctx context.Context) (source.LoginChallenge, error) {
	if hasRequiredCookies(p.api.cookieSnapshot()) {
		if status, err := p.LoginStatus(ctx); err == nil && status.LoggedIn {
			return source.LoginChallenge{LoggedIn: true}, nil
		}
	}
	p.closeLogin()
	jar, err := cookiejar.New(nil)
	if err != nil {
		return source.LoginChallenge{}, fmt.Errorf("创建知乎登录会话: %w", err)
	}
	loginClient := cloneHTTPClient(p.api.httpClient)
	loginClient.Jar = jar
	if err := p.loginGET(ctx, loginClient, p.api.endpoints.LoginURL); err != nil {
		return source.LoginChallenge{}, err
	}
	if err := p.loginPOST(ctx, loginClient, p.api.endpoints.BaseURL+"/udid", map[string]any{}); err != nil {
		return source.LoginChallenge{}, err
	}
	if err := p.loginGET(ctx, loginClient, p.api.endpoints.OAuthCaptcha); err != nil {
		return source.LoginChallenge{}, err
	}
	request, err := p.newLoginRequest(ctx, http.MethodPost, p.api.endpoints.QRCodeAPI, bytes.NewReader([]byte("{}")))
	if err != nil {
		return source.LoginChallenge{}, err
	}
	request.Header.Set("Content-Type", "application/json")
	setJarXSRF(request, jar, p.api.endpoints.BaseURL)
	response, err := loginClient.Do(request)
	if err != nil {
		return source.LoginChallenge{}, fmt.Errorf("获取知乎登录二维码: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 300))
		return source.LoginChallenge{}, fmt.Errorf("知乎二维码接口返回 HTTP %d: %s", response.StatusCode, strings.TrimSpace(string(body)))
	}
	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return source.LoginChallenge{}, fmt.Errorf("解析知乎登录二维码: %w", err)
	}
	token := firstString(payload["token"], payload["qrcode_token"])
	link := firstString(payload["link"], payload["url"])
	if token == "" || link == "" {
		return source.LoginChallenge{}, fmt.Errorf("知乎二维码接口未返回 token 和链接")
	}
	png, err := qrcode.Encode(link, qrcode.Medium, 320)
	if err != nil {
		return source.LoginChallenge{}, fmt.Errorf("生成知乎登录二维码: %w", err)
	}
	timeout := 2 * time.Minute
	p.auth.mu.Lock()
	p.auth.qr = &qrLoginSession{client: loginClient, jar: jar, token: token, expiresAt: time.Now().Add(timeout)}
	p.auth.mu.Unlock()
	return source.LoginChallenge{Image: png, Timeout: timeout}, nil
}

func (p *Provider) LoginStatus(ctx context.Context) (source.LoginStatus, error) {
	p.auth.mu.Lock()
	login := p.auth.qr
	p.auth.mu.Unlock()
	if login != nil {
		return p.pollQRCode(ctx, login)
	}
	cookies := p.api.cookieSnapshot()
	if !hasRequiredCookies(cookies) {
		return source.LoginStatus{}, nil
	}
	return p.validateCookies(ctx, cookies)
}

func (p *Provider) pollQRCode(ctx context.Context, login *qrLoginSession) (source.LoginStatus, error) {
	if time.Now().After(login.expiresAt) {
		p.closeLogin()
		return source.LoginStatus{}, fmt.Errorf("知乎登录二维码已过期")
	}
	target := p.api.endpoints.QRCodeAPI + "/" + url.PathEscape(login.token) + "/scan_info"
	request, err := p.newLoginRequest(ctx, http.MethodGet, target, nil)
	if err != nil {
		return source.LoginStatus{}, err
	}
	request.Header.Set("Referer", p.api.endpoints.BaseURL+"/signin?next=%2F")
	request.Header.Set("Accept", "*/*")
	request.Header.Set("x-requested-with", "fetch")
	request.Header.Set("x-zse-93", "101_3_3.0")
	setJarXSRF(request, login.jar, p.api.endpoints.BaseURL)
	response, err := login.client.Do(request)
	if err != nil {
		return source.LoginStatus{}, fmt.Errorf("检查知乎扫码状态: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusCreated {
		return source.LoginStatus{}, fmt.Errorf("知乎扫码状态接口返回 HTTP %d", response.StatusCode)
	}
	var payload map[string]any
	_ = json.NewDecoder(response.Body).Decode(&payload)
	applyLoginCookies(login.jar, p.api.endpoints.BaseURL, payload)
	cookies := cookiesFromJar(login.jar, p.api.endpoints)
	if !hasRequiredCookies(cookies) {
		return source.LoginStatus{}, nil
	}
	status, err := p.validateCookies(ctx, cookies)
	if err != nil {
		return source.LoginStatus{}, err
	}
	if err := saveSession(p.sessionPath, cookies); err != nil {
		return source.LoginStatus{}, err
	}
	p.api.setCookies(cookies)
	p.closeLogin()
	return status, nil
}

func (p *Provider) validateCookies(ctx context.Context, cookies map[string]string) (source.LoginStatus, error) {
	temporary := newAPIClient(p.api.httpClient, p.api.endpoints, cookies)
	profile, err := temporary.getMap(ctx, p.api.endpoints.APIV4+"/me", nil)
	if err != nil {
		return source.LoginStatus{}, fmt.Errorf("校验知乎登录: %w", err)
	}
	username := firstString(profile["name"], profile["url_token"])
	userID := firstString(profile["id"], profile["url_token"])
	if username == "" && userID == "" {
		return source.LoginStatus{}, fmt.Errorf("知乎登录校验未返回账号信息")
	}
	return source.LoginStatus{LoggedIn: true, Username: username, UserID: userID}, nil
}

func (p *Provider) closeLogin() {
	p.auth.mu.Lock()
	login := p.auth.qr
	p.auth.qr = nil
	p.auth.mu.Unlock()
	if login != nil {
		login.client.CloseIdleConnections()
	}
}

func cloneHTTPClient(client *http.Client) *http.Client {
	if client == nil {
		return &http.Client{Timeout: 45 * time.Second}
	}
	return &http.Client{
		Transport: client.Transport, CheckRedirect: client.CheckRedirect,
		Timeout: client.Timeout,
	}
}

func (p *Provider) loginGET(ctx context.Context, client *http.Client, target string) error {
	request, err := p.newLoginRequest(ctx, http.MethodGet, target, nil)
	if err != nil {
		return err
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("打开知乎登录页: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 400 {
		return fmt.Errorf("知乎登录准备接口返回 HTTP %d", response.StatusCode)
	}
	return nil
}

func (p *Provider) loginPOST(ctx context.Context, client *http.Client, target string, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	request, err := p.newLoginRequest(ctx, http.MethodPost, target, bytes.NewReader(data))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("准备知乎登录会话: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 400 {
		return fmt.Errorf("知乎登录准备接口返回 HTTP %d", response.StatusCode)
	}
	return nil
}

func (p *Provider) newLoginRequest(ctx context.Context, method, target string, body io.Reader) (*http.Request, error) {
	request, err := http.NewRequestWithContext(ctx, method, target, body)
	if err != nil {
		return nil, err
	}
	setBrowserHeaders(request)
	request.Header.Set("Referer", p.api.endpoints.BaseURL+"/")
	return request, nil
}

func setJarXSRF(request *http.Request, jar http.CookieJar, baseURL string) {
	parsed, _ := url.Parse(baseURL)
	for _, cookie := range jar.Cookies(parsed) {
		if cookie.Name == "_xsrf" {
			request.Header.Set("x-xsrftoken", cookie.Value)
			return
		}
	}
}

func applyLoginCookies(jar http.CookieJar, baseURL string, payload map[string]any) {
	parsed, _ := url.Parse(baseURL)
	for _, key := range []string{"cookie", "cookies"} {
		if raw := stringValue(payload[key]); raw != "" {
			jar.SetCookies(parsed, httpCookies(parseCookieString(raw)))
		}
	}
	if zc0 := stringValue(payload["z_c0"]); zc0 != "" {
		jar.SetCookies(parsed, []*http.Cookie{{Name: "z_c0", Value: zc0}})
	}
}

func httpCookies(values map[string]string) []*http.Cookie {
	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)
	cookies := make([]*http.Cookie, 0, len(names))
	for _, name := range names {
		cookies = append(cookies, &http.Cookie{Name: name, Value: values[name]})
	}
	return cookies
}

func cookiesFromJar(jar http.CookieJar, endpoints Endpoints) map[string]string {
	cookies := make(map[string]string)
	for _, rawURL := range []string{endpoints.BaseURL, endpoints.APIV4, endpoints.APIV3} {
		parsed, err := url.Parse(rawURL)
		if err != nil {
			continue
		}
		for _, cookie := range jar.Cookies(parsed) {
			cookies[cookie.Name] = cookie.Value
		}
	}
	return cookies
}
