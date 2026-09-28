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
	"math/rand/v2"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultBaseURL      = "https://www.zhihu.com"
	defaultAPIV4        = defaultBaseURL + "/api/v4"
	defaultAPIV3        = defaultBaseURL + "/api/v3"
	defaultZhuanlanAPI  = "https://zhuanlan.zhihu.com/api"
	defaultLoginURL     = defaultBaseURL + "/signin"
	defaultQRCodeAPI    = defaultAPIV3 + "/account/api/login/qrcode"
	defaultOAuthCaptcha = defaultAPIV3 + "/oauth/captcha/v2?type=captcha_sign_in"
	chromeVersion       = "145"
	defaultUserAgent    = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/" + chromeVersion + ".0.0.0 Safari/537.36"
	requestMaxAttempts  = 3
)

type Endpoints struct {
	BaseURL      string
	APIV4        string
	APIV3        string
	ZhuanlanAPI  string
	LoginURL     string
	QRCodeAPI    string
	OAuthCaptcha string
}

func defaultEndpoints() Endpoints {
	return Endpoints{
		BaseURL: defaultBaseURL, APIV4: defaultAPIV4, APIV3: defaultAPIV3,
		ZhuanlanAPI: defaultZhuanlanAPI, LoginURL: defaultLoginURL,
		QRCodeAPI: defaultQRCodeAPI, OAuthCaptcha: defaultOAuthCaptcha,
	}
}

func normalizeEndpoints(endpoints Endpoints) Endpoints {
	defaults := defaultEndpoints()
	if endpoints.BaseURL == "" {
		endpoints.BaseURL = defaults.BaseURL
	}
	if endpoints.APIV4 == "" {
		endpoints.APIV4 = defaults.APIV4
	}
	if endpoints.APIV3 == "" {
		endpoints.APIV3 = defaults.APIV3
	}
	if endpoints.ZhuanlanAPI == "" {
		endpoints.ZhuanlanAPI = defaults.ZhuanlanAPI
	}
	if endpoints.LoginURL == "" {
		endpoints.LoginURL = defaults.LoginURL
	}
	if endpoints.QRCodeAPI == "" {
		endpoints.QRCodeAPI = defaults.QRCodeAPI
	}
	if endpoints.OAuthCaptcha == "" {
		endpoints.OAuthCaptcha = defaults.OAuthCaptcha
	}
	return endpoints
}

type loginError struct{ message string }

func (e loginError) Error() string { return e.message }

type fetchError struct {
	message    string
	statusCode int
}

func (e fetchError) Error() string { return e.message }

type apiClient struct {
	httpClient *http.Client
	endpoints  Endpoints
	mu         sync.RWMutex
	cookies    map[string]string
}

func newAPIClient(httpClient *http.Client, endpoints Endpoints, cookies map[string]string) *apiClient {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 45 * time.Second}
	}
	client := &apiClient{httpClient: httpClient, endpoints: normalizeEndpoints(endpoints)}
	client.setCookies(cookies)
	return client
}

func (c *apiClient) setCookies(cookies map[string]string) {
	copied := make(map[string]string, len(cookies))
	for name, value := range cookies {
		copied[name] = value
	}
	c.mu.Lock()
	c.cookies = copied
	c.mu.Unlock()
}

func (c *apiClient) cookieSnapshot() map[string]string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	copied := make(map[string]string, len(c.cookies))
	for name, value := range c.cookies {
		copied[name] = value
	}
	return copied
}

func (c *apiClient) close() { c.httpClient.CloseIdleConnections() }

func (c *apiClient) getMap(ctx context.Context, target string, params url.Values) (map[string]any, error) {
	value, err := c.getJSON(ctx, target, params)
	if err != nil {
		return nil, err
	}
	result, ok := value.(map[string]any)
	if !ok {
		return nil, fetchError{message: "知乎接口返回的不是 JSON 对象"}
	}
	return result, nil
}

func (c *apiClient) getJSON(ctx context.Context, target string, params url.Values) (any, error) {
	if params != nil {
		separator := "?"
		if strings.Contains(target, "?") {
			separator = "&"
		}
		target += separator + params.Encode()
	}
	response, err := c.do(ctx, http.MethodGet, target, nil, nil)
	if err != nil {
		return nil, fetchError{message: fmt.Sprintf("请求知乎失败: %v", err)}
	}
	defer response.Body.Close()
	if err := checkExpectedStatus(response, map[int]bool{http.StatusOK: true}, "知乎接口"); err != nil {
		return nil, err
	}
	var result any
	decoder := json.NewDecoder(response.Body)
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		return nil, fetchError{message: fmt.Sprintf("解析知乎响应: %v", err)}
	}
	return result, nil
}

func (c *apiClient) mutateJSON(ctx context.Context, method, target string, payload any, accepted map[int]bool) (map[string]any, error) {
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(encoded)
	}
	response, err := c.do(ctx, method, target, body, map[string]string{"Content-Type": "application/json"})
	if err != nil {
		return nil, fetchError{message: fmt.Sprintf("请求知乎失败: %v", err)}
	}
	defer response.Body.Close()
	if err := checkExpectedStatus(response, accepted, "知乎写操作"); err != nil {
		return nil, err
	}
	var result map[string]any
	decoder := json.NewDecoder(response.Body)
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		if errors.Is(err, io.EOF) {
			return map[string]any{}, nil
		}
		return nil, fetchError{message: fmt.Sprintf("解析知乎响应: %v", err)}
	}
	return result, nil
}

func (c *apiClient) do(ctx context.Context, method, target string, body io.Reader, headers map[string]string) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, target, body)
	if err != nil {
		return nil, err
	}
	setBrowserHeaders(request)
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	cookies := c.cookieSnapshot()
	for name, value := range cookies {
		request.AddCookie(&http.Cookie{Name: name, Value: value})
	}
	if xsrf := cookies["_xsrf"]; xsrf != "" {
		request.Header.Set("x-xsrftoken", xsrf)
	}
	return c.doWithRetry(request)
}

func (c *apiClient) doWithRetry(request *http.Request) (*http.Response, error) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		return c.httpClient.Do(request)
	}
	for attempt := 0; ; attempt++ {
		if err := request.Context().Err(); err != nil {
			return nil, err
		}
		response, err := c.httpClient.Do(request)
		if attempt == requestMaxAttempts-1 || err == nil && !retryableResponse(response) {
			return response, err
		}
		if err != nil {
			response = nil
		}
		delay := retryDelay(attempt, response)
		if response != nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
			_ = response.Body.Close()
		}
		timer := time.NewTimer(delay)
		select {
		case <-request.Context().Done():
			timer.Stop()
			return nil, request.Context().Err()
		case <-timer.C:
		}
	}
}

func retryableResponse(response *http.Response) bool {
	if response == nil {
		return true
	}
	switch response.StatusCode {
	case http.StatusRequestTimeout, http.StatusTooManyRequests, http.StatusInternalServerError,
		http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return true
	case http.StatusForbidden:
	default:
		return false
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	response.Body = struct {
		io.Reader
		io.Closer
	}{Reader: io.MultiReader(bytes.NewReader(data), response.Body), Closer: response.Body}
	if err != nil {
		return false
	}
	var payload struct {
		Error struct {
			Code int `json:"code"`
		} `json:"error"`
	}
	return json.Unmarshal(data, &payload) == nil && payload.Error.Code == 10003
}

func retryDelay(attempt int, response *http.Response) time.Duration {
	base := 250 * time.Millisecond << attempt
	delay := base
	if response != nil {
		if seconds, err := strconv.Atoi(response.Header.Get("Retry-After")); err == nil && seconds >= 0 {
			delay = max(delay, time.Duration(seconds)*time.Second)
		} else if date, err := http.ParseTime(response.Header.Get("Retry-After")); err == nil {
			delay = max(delay, time.Until(date))
		}
	}
	return delay + rand.N(base)
}

func checkExpectedStatus(response *http.Response, accepted map[int]bool, label string) error {
	if response.StatusCode == http.StatusUnauthorized {
		return loginError{message: "知乎登录已失效，请重新登录"}
	}
	if accepted[response.StatusCode] {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(response.Body, 300))
	return fetchError{
		message:    fmt.Sprintf("%s返回 HTTP %d: %s", label, response.StatusCode, strings.TrimSpace(string(body))),
		statusCode: response.StatusCode,
	}
}

func setBrowserHeaders(request *http.Request) {
	request.Header.Set("User-Agent", defaultUserAgent)
	request.Header.Set("Accept", "application/json, text/plain, */*")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.7")
	request.Header.Set("Referer", defaultBaseURL+"/")
	request.Header.Set("sec-ch-ua", `"Not:A-Brand";v="99", "Google Chrome";v="`+chromeVersion+`", "Chromium";v="`+chromeVersion+`"`)
	request.Header.Set("sec-ch-ua-mobile", "?0")
	request.Header.Set("sec-ch-ua-platform", `"Windows"`)
}
