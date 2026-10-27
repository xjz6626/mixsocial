package zhihu

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/xjz6626/mixsocial/internal/domain"
)

func TestAuthorFollowAndUnfollowWithRemoteConfirmation(t *testing.T) {
	for _, mode := range []string{"success", "rejected", "business-error", "wrong-target", "missing-state", "unconfirmed", "read-failed"} {
		t.Run(mode, func(t *testing.T) {
			state, writes := false, 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("x-xsrftoken") != "csrf" {
					t.Error("missing XSRF header")
				}
				if cookie, err := r.Cookie("z_c0"); err != nil || cookie.Value != "session" {
					t.Error("missing logged-in session")
				}
				switch r.URL.Path {
				case "/api/v4/members/alice":
					if r.Method != http.MethodGet || r.URL.Query().Get("include") != "is_following" {
						t.Error("invalid state request")
					}
					if mode == "read-failed" && writes != 0 {
						http.Error(w, "unavailable", http.StatusBadRequest)
						return
					}
					member := map[string]any{"id": "u1", "url_token": "alice", "is_following": state}
					if mode == "wrong-target" {
						member["id"] = "u2"
					}
					if mode == "missing-state" {
						delete(member, "is_following")
					}
					writeTestJSON(t, w, member)
				case "/api/v4/members/alice/followers":
					writes++
					if r.Method != http.MethodPost && r.Method != http.MethodDelete {
						t.Fatal("wrong follow method")
					}
					if mode == "rejected" {
						http.Error(w, "rejected", http.StatusForbidden)
						return
					}
					if mode == "business-error" {
						writeTestJSON(t, w, map[string]any{"error": map[string]any{"code": 403}})
						return
					}
					if mode != "unconfirmed" {
						state = r.Method == http.MethodPost
					}
					w.WriteHeader(http.StatusNoContent)
				default:
					t.Errorf("unexpected path %s", r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			p := New(Config{Client: server.Client(), Endpoints: testEndpoints(server.URL)})
			p.api.setCookies(map[string]string{"z_c0": "session", "_xsrf": "csrf", "d_c0": "device"})
			ref := domain.ProfileRef{Source: domain.SourceZhihu, ID: "u1", Token: "alice"}
			err := p.Follow(context.Background(), ref, true)
			if mode != "success" {
				if err == nil {
					t.Fatal("unconfirmed follow reported success")
				}
				want := 1
				if mode == "wrong-target" || mode == "missing-state" {
					want = 0
				}
				if writes != want {
					t.Fatalf("writes=%d want=%d", writes, want)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := p.Follow(context.Background(), ref, true); err != nil || writes != 1 {
				t.Fatalf("repeated follow: writes=%d err=%v", writes, err)
			}
			if err := p.Follow(context.Background(), ref, false); err != nil {
				t.Fatal(err)
			}
			actual, err := p.Following(context.Background(), ref)
			if err != nil || actual || writes != 2 {
				t.Fatalf("unfollow: state=%v writes=%d err=%v", actual, writes, err)
			}
		})
	}
}

func TestAuthorFollowRejectsInvalidOrAnonymousTargetsWithoutRequests(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("invalid follow sent a request")
		http.NotFound(w, r)
	}))
	defer server.Close()
	p := New(Config{Client: server.Client(), Endpoints: testEndpoints(server.URL)})
	ref := domain.ProfileRef{Source: domain.SourceZhihu, ID: "u1", Token: "alice"}
	if p.Follow(context.Background(), ref, true) == nil {
		t.Fatal("logged out write accepted")
	}
	p.api.setCookies(map[string]string{"z_c0": "session", "_xsrf": "csrf", "d_c0": "device"})
	for _, ref := range []domain.ProfileRef{
		{Source: domain.SourceTieba, ID: "u1"}, {Source: domain.SourceZhihu, ID: "0"},
		{Source: domain.SourceZhihu, ID: "u1", Token: "alice/followers"},
	} {
		if p.Follow(context.Background(), ref, true) == nil {
			t.Fatal("invalid target accepted")
		}
	}
}
