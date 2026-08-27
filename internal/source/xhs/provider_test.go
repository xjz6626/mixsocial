package xhs

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) { return f(request) }

func jsonResponse(t *testing.T, request *http.Request, value any) (*http.Response, error) {
	t.Helper()
	var body bytes.Buffer
	if err := json.NewEncoder(&body).Encode(value); err != nil {
		t.Fatal(err)
	}
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(&body),
		Request:    request,
	}, nil
}

func TestSearchMapsFeedAndAuth(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/api/v1/feeds/search" || request.URL.Query().Get("keyword") != "终端" {
			t.Errorf("unexpected URL: %s", request.URL.String())
		}
		if request.Header.Get("Authorization") != "Bearer secret" {
			t.Errorf("missing auth header")
		}
		return jsonResponse(t, request, map[string]any{
			"success": true,
			"data": map[string]any{
				"count": 1,
				"feeds": []any{map[string]any{
					"id": "note-1", "xsecToken": "token-1", "modelType": "note",
					"noteCard": map[string]any{
						"displayTitle": "Terminal life",
						"user":         map[string]any{"userId": "u1", "nickname": "alice"},
						"interactInfo": map[string]any{"likedCount": "1.2万", "commentCount": "7"},
						"cover":        map[string]any{"urlDefault": "https://img.example/1", "width": 100, "height": 200},
					},
				}},
			},
		})
	})}

	provider := New(Config{Endpoint: "http://xhs.test", Token: "secret", Client: client})
	page, err := provider.Search(context.Background(), "终端", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.Items[0].Stats.Likes != 12000 || page.Items[0].Author.Name != "alice" {
		t.Fatalf("unexpected page: %+v", page)
	}
	if page.Items[0].Author.Ref.Source != domain.SourceXHS || page.Items[0].Author.Ref.ID != "u1" || !strings.Contains(page.Items[0].Author.Ref.URL, "xsec_token=token-1") {
		t.Fatalf("unexpected author profile ref: %+v", page.Items[0].Author.Ref)
	}
}

func TestDetailMapsComments(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		return jsonResponse(t, request, map[string]any{
			"success": true,
			"data": map[string]any{"feed_id": "n1", "data": map[string]any{
				"note":     map[string]any{"noteId": "n1", "title": "Title", "desc": "Body", "user": map[string]any{"nickname": "bob"}},
				"comments": map[string]any{"list": []any{map[string]any{"id": "c1", "content": "nice", "userInfo": map[string]any{"nickname": "eve"}}}},
			}},
		})
	})}

	provider := New(Config{Endpoint: "http://xhs.test", Client: client})
	detail, err := provider.Detail(context.Background(), domain.Ref{Source: domain.SourceXHS, ID: "n1", Token: "tok"})
	if err != nil {
		t.Fatal(err)
	}
	if detail.Body != "Body" || len(detail.Comments) != 1 || detail.Comments[0].Body != "nice" {
		t.Fatalf("unexpected detail: %+v", detail)
	}
}

func TestDetailMapsVideoStreamAndFeedCover(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		return jsonResponse(t, request, map[string]any{
			"success": true,
			"data": map[string]any{"feed_id": "v1", "data": map[string]any{
				"note": map[string]any{
					"noteId": "v1", "title": "Video", "type": "video",
					"video": map[string]any{
						"capa": map[string]any{"duration": 13},
						"media": map[string]any{"stream": map[string]any{"h264": []any{
							map[string]any{"masterUrl": "https://video.example/v1.mp4", "width": 720, "height": 1280, "duration": 12500, "streamDesc": "HD", "defaultStream": 1},
						}}},
					},
				},
				"comments": map[string]any{"list": []any{}},
			}},
		})
	})}
	provider := New(Config{Endpoint: "http://xhs.test", Client: client})
	detail, err := provider.Detail(context.Background(), domain.Ref{Source: domain.SourceXHS, ID: "v1", Token: "tok"})
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.Media) != 1 || detail.Media[0].Kind != "video" || detail.Media[0].URL != "https://video.example/v1.mp4" || detail.Media[0].Duration != 12500*time.Millisecond {
		t.Fatalf("unexpected video media: %+v", detail.Media)
	}
	feedItem := mapFeed(feed{ID: "v1", ModelType: "note", NoteCard: noteCard{
		Type: "video", Cover: cover{URLDefault: "https://img.example/v1.jpg"}, Video: &video{Capa: videoCapability{Duration: 13}},
	}})
	if len(feedItem.Media) != 1 || feedItem.Media[0].Kind != "video" || feedItem.Media[0].PreviewURL == "" || feedItem.Media[0].Duration != 13*time.Second {
		t.Fatalf("unexpected video cover: %+v", feedItem.Media)
	}
}

func TestLoginQRCodeAndStatus(t *testing.T) {
	image := []byte("png bytes")
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/api/v1/login/qrcode":
			return jsonResponse(t, request, map[string]any{
				"success": true,
				"data": map[string]any{
					"is_logged_in": false,
					"timeout":      "240s",
					"img":          "data:image/png;base64," + base64.StdEncoding.EncodeToString(image),
				},
			})
		case "/api/v1/login/status":
			return jsonResponse(t, request, map[string]any{
				"success": true,
				"data":    map[string]any{"is_logged_in": true, "username": "alice", "user_id": "u1"},
			})
		default:
			t.Fatalf("unexpected path %s", request.URL.Path)
			return nil, nil
		}
	})}
	provider := New(Config{Endpoint: "http://xhs.test", Client: client})
	challenge, err := provider.LoginQRCode(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if string(challenge.Image) != string(image) || challenge.Timeout.Seconds() != 240 {
		t.Fatalf("unexpected challenge: %+v", challenge)
	}
	status, err := provider.LoginStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !status.LoggedIn || status.Username != "alice" || status.UserID != "u1" {
		t.Fatalf("unexpected status: %+v", status)
	}
}

func TestBrowseHotSortsRecommendationSample(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/api/v1/feeds/list" {
			t.Fatalf("unexpected path %s", request.URL.Path)
		}
		return jsonResponse(t, request, map[string]any{
			"success": true,
			"data": map[string]any{"feeds": []any{
				map[string]any{"id": "low", "modelType": "note", "noteCard": map[string]any{"displayTitle": "low", "interactInfo": map[string]any{"likedCount": "1"}}},
				map[string]any{"id": "high", "modelType": "note", "noteCard": map[string]any{"displayTitle": "high", "interactInfo": map[string]any{"commentCount": "10"}}},
			}},
		})
	})}
	provider := New(Config{Endpoint: "http://xhs.test", Client: client})
	page, err := provider.Browse(context.Background(), source.ChannelHot, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 2 || page.Items[0].Ref.ID != "high" || !strings.Contains(strings.Join(page.Notices, " "), "官方热榜") {
		t.Fatalf("unexpected hot page: %+v", page)
	}
	following, err := provider.Browse(context.Background(), source.ChannelFollowing, "")
	if err != nil || len(following.Items) != 0 || len(following.Notices) == 0 {
		t.Fatalf("unexpected following capability notice: %+v, %v", following, err)
	}
}

func TestQRCodePollingWatchesSessionWithoutStartingAnotherBrowser(t *testing.T) {
	sessionPath := filepath.Join(t.TempDir(), "xhs-session.json")
	if err := os.WriteFile(sessionPath, []byte(`{"version":2,"cookies":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var statusRequests atomic.Int32
	image := []byte("qr image")
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/api/v1/login/qrcode":
			return jsonResponse(t, request, map[string]any{
				"success": true,
				"data":    map[string]any{"is_logged_in": false, "timeout": "240s", "img": base64.StdEncoding.EncodeToString(image)},
			})
		case "/api/v1/login/status":
			statusRequests.Add(1)
			return jsonResponse(t, request, map[string]any{"success": true, "data": map[string]any{"is_logged_in": false}})
		default:
			t.Fatalf("unexpected path %s", request.URL.Path)
			return nil, nil
		}
	})}
	provider := New(Config{Endpoint: "http://xhs.test", Client: client, SessionPath: sessionPath})
	if _, err := provider.LoginQRCode(context.Background()); err != nil {
		t.Fatal(err)
	}
	status, err := provider.LoginStatus(context.Background())
	if err != nil || status.LoggedIn || statusRequests.Load() != 0 {
		t.Fatalf("poll before scan = %+v, err=%v, HTTP status calls=%d", status, err, statusRequests.Load())
	}
	if err := os.WriteFile(sessionPath, []byte(`{"version":2,"saved_at":"later","cookies":[{"name":"web_session","value":"redacted"}]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	status, err = provider.LoginStatus(context.Background())
	if err != nil || !status.LoggedIn || statusRequests.Load() != 0 {
		t.Fatalf("poll after scan = %+v, err=%v, HTTP status calls=%d", status, err, statusRequests.Load())
	}
	info, err := os.Stat(sessionPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("session mode = %o", info.Mode().Perm())
	}
}

func TestManagedProviderDoesNotStartFeedBrowserBeforeLogin(t *testing.T) {
	sessionPath := filepath.Join(t.TempDir(), "xhs-session.json")
	if err := os.WriteFile(sessionPath, []byte(`{"version":2,"cookies":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		requests.Add(1)
		return jsonResponse(t, request, map[string]any{"success": true, "data": map[string]any{"feeds": []any{}}})
	})}
	provider := New(Config{Endpoint: "http://xhs.test", Client: client, SessionPath: sessionPath, GuardSession: true})
	_, err := provider.Feed(context.Background(), "")
	if err == nil || !strings.Contains(err.Error(), "按 L 扫码") {
		t.Fatalf("feed before login error = %v", err)
	}
	if requests.Load() != 0 {
		t.Fatalf("feed started %d sidecar requests before login", requests.Load())
	}
}
