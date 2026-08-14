package tieba

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/xjz6626/mixsocial/internal/source"
)

const (
	latestVersion    = "22.6.5.1"
	appSalt          = "tiebaclient!!!"
	defaultLoginURL  = "https://tiebac.baidu.com/c/s/login"
	defaultFollowURL = "https://tieba.baidu.com/c/f/forum/forumGuide"
)

type sessionData struct {
	BDUSS     string    `json:"bduss"`
	STOKEN    string    `json:"stoken,omitempty"`
	TBS       string    `json:"tbs"`
	UserID    string    `json:"user_id"`
	Username  string    `json:"username"`
	Validated time.Time `json:"validated_at"`
}

func (p *Provider) loadSession() {
	if p.sessionPath == "" {
		return
	}
	encoded, err := os.ReadFile(p.sessionPath)
	if os.IsNotExist(err) {
		return
	}
	if err != nil {
		p.sessionErr = fmt.Errorf("读取贴吧会话: %w", err)
		return
	}
	var session sessionData
	if err := json.Unmarshal(encoded, &session); err != nil {
		p.sessionErr = fmt.Errorf("解析贴吧会话: %w", err)
		return
	}
	if session.BDUSS == "" {
		p.sessionErr = fmt.Errorf("贴吧会话缺少 BDUSS")
		return
	}
	p.session = session
}

func (p *Provider) hasSession() bool {
	p.sessionMu.RLock()
	defer p.sessionMu.RUnlock()
	return p.session.BDUSS != ""
}

func (p *Provider) sessionSnapshot() (sessionData, error) {
	p.sessionMu.RLock()
	defer p.sessionMu.RUnlock()
	if p.sessionErr != nil {
		return sessionData{}, p.sessionErr
	}
	return p.session, nil
}

func (p *Provider) LoginStatus(ctx context.Context) (source.LoginStatus, error) {
	if status, active, err := p.browserLoginStatus(ctx); active {
		return status, err
	}
	session, err := p.sessionSnapshot()
	if err != nil {
		return source.LoginStatus{}, err
	}
	if session.BDUSS == "" {
		return source.LoginStatus{}, nil
	}
	validated, err := p.validateSession(ctx, session)
	if err != nil {
		return source.LoginStatus{}, err
	}
	if err := p.setSession(validated); err != nil {
		return source.LoginStatus{}, err
	}
	return loginStatus(validated), nil
}

func (p *Provider) LoginWithCredential(ctx context.Context, credential string) (source.LoginStatus, error) {
	session, err := parseCredential(credential)
	if err != nil {
		return source.LoginStatus{}, err
	}
	validated, err := p.validateSession(ctx, session)
	if err != nil {
		return source.LoginStatus{}, err
	}
	if err := p.setSession(validated); err != nil {
		return source.LoginStatus{}, err
	}
	return loginStatus(validated), nil
}

func loginStatus(session sessionData) source.LoginStatus {
	return source.LoginStatus{LoggedIn: session.BDUSS != "", Username: session.Username, UserID: session.UserID}
}

func parseCredential(input string) (sessionData, error) {
	input = strings.TrimSpace(input)
	if input == "" {
		return sessionData{}, fmt.Errorf("BDUSS 不能为空")
	}
	if strings.ContainsAny(input, "\r\n") {
		return sessionData{}, fmt.Errorf("BDUSS 不能包含换行")
	}
	session := sessionData{}
	if !strings.Contains(input, "=") {
		session.BDUSS = input
	} else {
		for _, part := range strings.Split(input, ";") {
			key, value, ok := strings.Cut(strings.TrimSpace(part), "=")
			if !ok {
				continue
			}
			switch strings.ToUpper(strings.TrimSpace(key)) {
			case "BDUSS":
				session.BDUSS = strings.TrimSpace(value)
			case "STOKEN":
				session.STOKEN = strings.TrimSpace(value)
			}
		}
	}
	if length := len(session.BDUSS); length < 64 || length > 512 {
		return sessionData{}, fmt.Errorf("BDUSS 长度异常；请从 tieba.baidu.com 的 Cookie 中复制完整 BDUSS")
	}
	return session, nil
}

func (p *Provider) validateSession(ctx context.Context, session sessionData) (sessionData, error) {
	form := []formValue{
		{key: "_client_version", value: latestVersion},
		{key: "bdusstoken", value: session.BDUSS},
	}
	body, err := p.postSignedForm(ctx, p.loginURL, form)
	if err != nil {
		return sessionData{}, err
	}
	var payload struct {
		ErrorCode json.RawMessage `json:"error_code"`
		ErrorMsg  string          `json:"error_msg"`
		User      struct {
			ID   json.RawMessage `json:"id"`
			Name string          `json:"name"`
		} `json:"user"`
		Anti struct {
			TBS string `json:"tbs"`
		} `json:"anti"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return sessionData{}, fmt.Errorf("解析贴吧登录响应: %w", err)
	}
	if code := rawScalar(payload.ErrorCode); code != "" && code != "0" {
		return sessionData{}, fmt.Errorf("贴吧登录失败 (%s): %s", code, fallback(payload.ErrorMsg, "BDUSS 已失效或触发风控"))
	}
	session.UserID = rawScalar(payload.User.ID)
	session.Username = payload.User.Name
	session.TBS = payload.Anti.TBS
	session.Validated = time.Now()
	if session.UserID == "" || session.TBS == "" {
		return sessionData{}, fmt.Errorf("贴吧登录响应缺少账号信息")
	}
	return session, nil
}

type formValue struct {
	key   string
	value string
}

func (p *Provider) postSignedForm(ctx context.Context, endpoint string, form []formValue) ([]byte, error) {
	signed := append([]formValue(nil), form...)
	sort.Slice(signed, func(i, j int) bool {
		if signed[i].key == signed[j].key {
			return signed[i].value < signed[j].value
		}
		return signed[i].key < signed[j].key
	})
	digest := md5.New() // Tieba's protocol-defined request signature, not a password hash.
	for _, entry := range signed {
		_, _ = io.WriteString(digest, entry.key+"="+entry.value)
	}
	_, _ = io.WriteString(digest, appSalt)
	signature := hex.EncodeToString(digest.Sum(nil))

	values := url.Values{}
	for _, entry := range form {
		values.Add(entry.key, entry.value)
	}
	values.Set("sign", signature)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(values.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", "mixsocial-tui/0.2")
	return p.readResponse(req, "贴吧登录")
}

func (p *Provider) setSession(session sessionData) error {
	if p.sessionPath != "" {
		if err := saveSession(p.sessionPath, session); err != nil {
			return err
		}
	}
	p.sessionMu.Lock()
	p.session = session
	p.sessionErr = nil
	p.sessionMu.Unlock()
	return nil
}

func saveSession(path string, session sessionData) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("创建贴吧会话目录: %w", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return fmt.Errorf("保护贴吧会话目录: %w", err)
	}
	encoded, err := json.MarshalIndent(session, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".tieba-session-*")
	if err != nil {
		return fmt.Errorf("创建贴吧临时会话: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("保护贴吧临时会话: %w", err)
	}
	if _, err := temporary.Write(encoded); err != nil {
		temporary.Close()
		return fmt.Errorf("写入贴吧会话: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("同步贴吧会话: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("关闭贴吧会话: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("保存贴吧会话: %w", err)
	}
	return nil
}

func rawScalar(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	return strings.TrimSpace(string(raw))
}

func fallback(value, defaultValue string) string {
	if strings.TrimSpace(value) != "" {
		return value
	}
	return defaultValue
}
