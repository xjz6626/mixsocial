package zhihu

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
)

func TestBrowseDetailAndComments(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api/v3/feed/topstory/recommend":
			if request.URL.Query().Get("limit") != "10" || request.URL.Query().Get("action") != "down" {
				t.Fatalf("unexpected feed query: %s", request.URL.RawQuery)
			}
			writeTestJSON(t, writer, map[string]any{
				"data": []any{map[string]any{
					"target": map[string]any{
						"type": "answer", "id": 42,
						"question":     map[string]any{"id": 7, "title": "为什么使用 Go？"},
						"author":       map[string]any{"id": "u1", "url_token": "alice", "name": "Alice", "avatar_url": "https://pic.example/avatar.jpg"},
						"content":      `<p>并发简单。</p><img src="https://pic.example/full.jpg" data-rawwidth="1080" data-rawheight="720">`,
						"voteup_count": 12, "comment_count": 3, "created_time": 1_700_000_000,
						"relationship": map[string]any{"voting": 1},
					},
				}},
				"paging": map[string]any{"is_end": false, "next": server.URL + "/api/v3/feed/topstory/recommend?after_id=42"},
			})
		case "/api/v4/answers/42":
			writeTestJSON(t, writer, map[string]any{
				"type": "answer", "id": 42,
				"question":     map[string]any{"id": 7, "title": "为什么使用 Go？"},
				"author":       map[string]any{"id": "u1", "url_token": "alice", "name": "Alice"},
				"content":      `<p>完整正文</p><img data-original="https://pic.example/original.webp">`,
				"voteup_count": 12, "comment_count": 3,
			})
		case "/api/v4/comment_v5/answers/42/root_comment":
			if request.URL.Query().Get("offset") == "10" {
				writeTestJSON(t, writer, map[string]any{
					"data": []any{map[string]any{
						"id": 102, "content": "下一页评论", "author": map[string]any{"name": "Dave"},
					}},
					"paging": map[string]any{"is_end": true},
				})
				return
			}
			writeTestJSON(t, writer, map[string]any{
				"data": []any{map[string]any{
					"id": 100, "content": "<p>根评论</p>", "vote_count": 5, "child_comment_count": 1,
					"author":         map[string]any{"member": map[string]any{"id": "u2", "url_token": "bob", "name": "Bob"}},
					"child_comments": []any{map[string]any{"id": 101, "content": "子回复", "author": map[string]any{"name": "Carol"}}},
				}},
				"paging": map[string]any{"is_end": true},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	provider := New(Config{Client: server.Client(), Endpoints: testEndpoints(server.URL)})
	page, err := provider.Browse(context.Background(), source.ChannelRecommend, "")
	if err != nil {
		t.Fatalf("Browse: %v", err)
	}
	if len(page.Items) != 1 || !page.HasMore || !strings.Contains(page.NextCursor, "after_id=42") {
		t.Fatalf("unexpected page: %+v", page)
	}
	item := page.Items[0]
	if item.Ref.Token != "answer" || item.Ref.ParentID != "7" || item.Title != "为什么使用 Go？" || item.Author.Name != "Alice" {
		t.Fatalf("unexpected item: %+v", item)
	}
	if !item.Liked || item.Stats.Likes != 12 || len(item.Media) != 1 || item.Media[0].Width != 1080 {
		t.Fatalf("unexpected item state: %+v", item)
	}

	detail, err := provider.Detail(context.Background(), item.Ref)
	if err != nil {
		t.Fatalf("Detail: %v", err)
	}
	if detail.Body != "完整正文" || len(detail.Media) != 1 || detail.Media[0].URL != "https://pic.example/original.webp" {
		t.Fatalf("unexpected detail: %+v", detail)
	}
	if len(detail.Comments) != 1 || detail.Comments[0].Body != "根评论" || len(detail.Comments[0].Replies) != 1 || detail.Comments[0].Replies[0].Body != "子回复" {
		t.Fatalf("unexpected comments: %+v", detail.Comments)
	}
	next, err := provider.Comments(context.Background(), item.Ref, "10")
	if err != nil || len(next.Comments) != 1 || next.Comments[0].Body != "下一页评论" {
		t.Fatalf("Comments: page=%+v err=%v", next, err)
	}
}

func TestSearchAndHotMapping(t *testing.T) {
	var hotRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api/v4/search_v3":
			if request.URL.Query().Get("q") != "终端" || request.URL.Query().Get("offset") != "0" {
				t.Fatalf("unexpected search query: %s", request.URL.RawQuery)
			}
			writeTestJSON(t, writer, map[string]any{
				"data": []any{map[string]any{"object": map[string]any{
					"type": "article", "id": 9, "title": "终端阅读", "excerpt": "摘要", "author": map[string]any{"name": "作者"},
				}}},
				"paging": map[string]any{"is_end": false},
			})
		case "/api/v4/creators/rank/hot":
			requestNumber := hotRequests.Add(1)
			if requestNumber == 2 && request.URL.Query().Get("offset") != "1" {
				t.Fatalf("relative hot-list cursor was not resolved against /api/v4: %s", request.URL.String())
			}
			writeTestJSON(t, writer, map[string]any{
				"data": []any{map[string]any{
					"question": map[string]any{"type": "question", "id": 8, "title": "热门问题"},
					"reaction": map[string]any{"pv": 100, "upvote_num": 20, "answer_num": 3},
				}},
				"paging": map[string]any{
					"is_end": requestNumber == 2,
					"next":   "/creators/rank/hot?domain=0&limit=10&offset=1",
				},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()
	provider := New(Config{Client: server.Client(), Endpoints: testEndpoints(server.URL)})

	searchPage, err := provider.Search(context.Background(), "终端", "")
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(searchPage.Items) != 1 || searchPage.Items[0].Ref.Token != "article" || searchPage.NextCursor != "1" || !searchPage.HasMore {
		t.Fatalf("unexpected search page: %+v", searchPage)
	}
	hotPage, err := provider.Browse(context.Background(), source.ChannelHot, "")
	if err != nil {
		t.Fatalf("Hot: %v", err)
	}
	if len(hotPage.Items) != 1 || hotPage.Items[0].Title != "热门问题" || hotPage.Items[0].Ref.Token != "question" || hotPage.Items[0].Stats.Views != 100 {
		t.Fatalf("unexpected hot page: %+v", hotPage)
	}
	if !hotPage.HasMore || hotPage.NextCursor == "" {
		t.Fatalf("hot page lost its relative cursor: %+v", hotPage)
	}
	if _, err := provider.Browse(context.Background(), source.ChannelHot, hotPage.NextCursor); err != nil {
		t.Fatalf("second hot page: %v", err)
	}
}

func TestCookieLoginAndMutations(t *testing.T) {
	var (
		mu       sync.Mutex
		payloads []map[string]any
	)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/api/v4/me" {
			cookies := request.Header.Get("Cookie")
			if !strings.Contains(cookies, "z_c0=zc") || request.Header.Get("x-xsrftoken") != "xs" {
				t.Fatalf("missing login headers: Cookie=%q xsrf=%q", cookies, request.Header.Get("x-xsrftoken"))
			}
			writeTestJSON(t, writer, map[string]any{"id": "user-1", "name": "测试用户", "url_token": "tester"})
			return
		}
		if request.URL.Path == "/api/v4/answers/42/voters" {
			var payload map[string]any
			_ = json.NewDecoder(request.Body).Decode(&payload)
			if payload["type"] != "up" {
				t.Fatalf("unexpected vote payload: %#v", payload)
			}
			writeTestJSON(t, writer, map[string]any{"voting": 1})
			return
		}
		if request.URL.Path == "/api/v4/comment_v5/answers/42/comment" {
			var payload map[string]any
			_ = json.NewDecoder(request.Body).Decode(&payload)
			mu.Lock()
			payloads = append(payloads, payload)
			mu.Unlock()
			writer.WriteHeader(http.StatusCreated)
			writeTestJSON(t, writer, map[string]any{"id": len(payloads)})
			return
		}
		http.NotFound(writer, request)
	}))
	defer server.Close()

	sessionPath := filepath.Join(t.TempDir(), "state", "zhihu-session.json")
	provider := New(Config{Client: server.Client(), SessionPath: sessionPath, Endpoints: testEndpoints(server.URL)})
	status, err := provider.LoginWithCredential(context.Background(), "z_c0=zc; _xsrf=xs; d_c0=dc")
	if err != nil || !status.LoggedIn || status.Username != "测试用户" {
		t.Fatalf("LoginWithCredential status=%+v err=%v", status, err)
	}
	info, err := os.Stat(sessionPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("session mode=%v err=%v", info, err)
	}
	ref := domain.Ref{Source: domain.SourceZhihu, ID: "42", Token: "answer"}
	if err := provider.Like(context.Background(), ref, true); err != nil {
		t.Fatalf("Like: %v", err)
	}
	if err := provider.Comment(context.Background(), ref, "评论"); err != nil {
		t.Fatalf("Comment: %v", err)
	}
	if err := provider.Reply(context.Background(), ref, domain.Ref{Source: domain.SourceZhihu, ID: "100"}, "回复"); err != nil {
		t.Fatalf("Reply: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(payloads) != 2 || payloads[0]["content"] != "评论" || payloads[1]["reply_comment_id"] != "100" {
		t.Fatalf("unexpected comment payloads: %#v", payloads)
	}
	if provider.Capabilities().Has(source.CapabilityFavorite) {
		t.Fatal("Zhihu unexpectedly advertises favorite support")
	}
}

func TestQRCodeLogin(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/signin":
			http.SetCookie(writer, &http.Cookie{Name: "_xsrf", Value: "xs", Path: "/"})
			http.SetCookie(writer, &http.Cookie{Name: "d_c0", Value: "dc", Path: "/"})
			writer.WriteHeader(http.StatusOK)
		case "/udid", "/api/v3/oauth/captcha/v2":
			writer.WriteHeader(http.StatusOK)
		case "/api/v3/account/api/login/qrcode":
			writeTestJSON(t, writer, map[string]any{"token": "qr-token", "link": "https://www.zhihu.com/account/scan"})
		case "/api/v3/account/api/login/qrcode/qr-token/scan_info":
			writeTestJSON(t, writer, map[string]any{"z_c0": "zc"})
		case "/api/v4/me":
			writeTestJSON(t, writer, map[string]any{"id": "u1", "name": "扫码用户"})
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	sessionPath := filepath.Join(t.TempDir(), "zhihu.json")
	provider := New(Config{Client: server.Client(), SessionPath: sessionPath, Endpoints: testEndpoints(server.URL)})
	challenge, err := provider.LoginQRCode(context.Background())
	if err != nil || challenge.LoggedIn || len(challenge.Image) == 0 {
		t.Fatalf("LoginQRCode challenge=%+v err=%v", challenge, err)
	}
	status, err := provider.LoginStatus(context.Background())
	if err != nil || !status.LoggedIn || status.Username != "扫码用户" {
		t.Fatalf("LoginStatus status=%+v err=%v", status, err)
	}
}

func testEndpoints(base string) Endpoints {
	return Endpoints{
		BaseURL: base, APIV4: base + "/api/v4", APIV3: base + "/api/v3",
		ZhuanlanAPI: base + "/zhuanlan/api", LoginURL: base + "/signin",
		QRCodeAPI:    base + "/api/v3/account/api/login/qrcode",
		OAuthCaptcha: base + "/api/v3/oauth/captcha/v2?type=captcha_sign_in",
	}
}

func writeTestJSON(t *testing.T, writer http.ResponseWriter, value any) {
	t.Helper()
	writer.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(writer).Encode(value); err != nil {
		t.Fatal(err)
	}
}
