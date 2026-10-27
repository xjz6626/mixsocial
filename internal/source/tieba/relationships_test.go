package tieba

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"testing"

	"github.com/xjz6626/mixsocial/internal/domain"
)

func TestAuthorFollowProtocolAndState(t *testing.T) {
	for _, mode := range []string{"success", "rejected", "missing-code", "wrong-target", "unconfirmed", "lost-response"} {
		t.Run(mode, func(t *testing.T) {
			state, writes := false, 0
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				var body string
				if r.URL.Path == "/c/u/user/profile" {
					reader, _ := r.MultipartReader()
					var encoded []byte
					for {
						part, err := reader.NextPart()
						if err == io.EOF {
							break
						}
						if err != nil {
							t.Fatal(err)
						}
						value, _ := io.ReadAll(part)
						if part.FormName() == "data" {
							encoded = value
						}
					}
					root, _ := parseFields(encoded)
					data, _ := parseFields(firstBytes(root, 1))
					common, _ := parseFields(firstBytes(data, 9))
					if firstUint(data, 1) != 42 || firstString(common, 10) != "credential" || firstString(common, 11) != "tbs-token" {
						t.Fatal("profile query lost target or login identity")
					}
					uid := uint64(42)
					if mode == "wrong-target" {
						uid = 99
					}
					user := appendUint(nil, 2, uid)
					user = appendString(user, 5, "tb.1.canonical-portrait?t=1700000000")
					if state {
						user = appendUint(user, 46, 1)
					}
					body = string(appendBytes(appendBytes(nil, 1, []byte{}), 2, appendBytes(nil, 1, user)))
				} else {
					writes++
					if err := r.ParseForm(); err != nil {
						t.Fatal(err)
					}
					if r.Form.Get("portrait") != "tb.1.canonical-portrait" || r.Form.Get("BDUSS") != "credential" || r.Form.Get("tbs") != "tbs-token" {
						t.Fatalf("invalid follow target or auth: %s", r.URL.Path)
					}
					verifyRelationshipSignature(t, r)
					switch r.URL.Path {
					case "/c/c/user/follow":
						state = true
					case "/c/c/user/unfollow":
						state = false
					default:
						t.Fatalf("unexpected path %s", r.URL.Path)
					}
					body = `{"error_code":"0"}`
					switch mode {
					case "rejected":
						body = `{"error_code":"5","error_msg":"rejected"}`
					case "missing-code":
						body = `{}`
					case "unconfirmed":
						state = false
					case "lost-response":
						return nil, fmt.Errorf("connection reset")
					}
				}
				return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}, nil
			})}
			p := New(Config{Client: client})
			p.session = sessionData{BDUSS: "credential", TBS: "tbs-token", UserID: "1"}
			ref := domain.ProfileRef{Source: domain.SourceTieba, ID: "42", Token: "wrong-cached-portrait"}
			err := p.Follow(context.Background(), ref, true)
			if mode == "success" {
				if err != nil {
					t.Fatal(err)
				}
				if err := p.Follow(context.Background(), ref, true); err != nil {
					t.Fatal(err)
				}
				if writes != 1 {
					t.Fatal("already-followed state caused a repeated write")
				}
				if err := p.Follow(context.Background(), ref, false); err != nil {
					t.Fatal(err)
				}
				actual, err := p.Following(context.Background(), ref)
				if err != nil || actual || writes != 2 {
					t.Fatalf("unfollow state=%v writes=%d err=%v", actual, writes, err)
				}
			} else {
				if err == nil {
					t.Fatal("unconfirmed action reported success")
				}
				want := 1
				if mode == "wrong-target" {
					want = 0
				}
				if writes != want {
					t.Fatalf("writes=%d want %d", writes, want)
				}
			}
		})
	}
}

func verifyRelationshipSignature(t *testing.T, r *http.Request) {
	t.Helper()
	keys := []string{}
	for key := range r.Form {
		if key != "sign" {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	var payload strings.Builder
	for _, key := range keys {
		payload.WriteString(key + "=" + r.Form.Get(key))
	}
	payload.WriteString(appSalt)
	digest := md5.Sum([]byte(payload.String()))
	if r.Form.Get("sign") != hex.EncodeToString(digest[:]) {
		t.Fatal("invalid protocol signature")
	}
}

func TestForumFollowProtocolAndConfirmation(t *testing.T) {
	for _, reject := range []bool{false, true} {
		state, writes := false, 0
		client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			body := `{"error_code":0}`
			switch r.URL.Path {
			case "/f/commit/share/fnameShareApi":
				if r.URL.Query().Get("fname") != "golang" {
					t.Fatal("forum name not normalized")
				}
				body = `{"no":0,"data":{"fid":"123","fname":"golang"}}`
			case "/c/f/forum/forumGuide":
				body = `{"error_code":0,"like_forum":[],"like_forum_has_more":false}`
				if state {
					body = `{"error_code":0,"like_forum":[{"forum_name":"golang"}],"like_forum_has_more":false}`
				}
			case "/c/c/forum/like", "/c/c/forum/unfavolike":
				writes++
				_ = r.ParseForm()
				verifyRelationshipSignature(t, r)
				if r.Form.Get("fid") != "123" || r.Form.Get("BDUSS") != "credential" || r.Form.Get("tbs") != "tbs-token" {
					t.Fatal("wrong forum target or credentials")
				}
				state = r.URL.Path == "/c/c/forum/like"
				if reject {
					body = `{"error_code":0,"error":{"errno":8,"errmsg":"rejected"}}`
				}
			default:
				t.Fatalf("unexpected path %s", r.URL.Path)
			}
			return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}, nil
		})}
		p := New(Config{Client: client})
		p.session = sessionData{BDUSS: "credential", TBS: "tbs-token"}
		err := p.FollowForum(context.Background(), " golang吧 ", true)
		if reject {
			if err == nil || writes != 1 {
				t.Fatal("nested rejection accepted or retried")
			}
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if err := p.FollowForum(context.Background(), "golang", true); err != nil || writes != 1 {
			t.Fatalf("idempotency err=%v writes=%d", err, writes)
		}
		if err := p.FollowForum(context.Background(), "golang", false); err != nil || state || writes != 2 {
			t.Fatalf("unfollow err=%v state=%v writes=%d", err, state, writes)
		}
	}
}

func TestFollowRejectsInvalidTargetsAndLoggedOutSessions(t *testing.T) {
	p := New(Config{Client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { t.Fatal("invalid action sent a request"); return nil, nil })}})
	ref := domain.ProfileRef{Source: domain.SourceTieba, ID: "42"}
	if p.Follow(context.Background(), ref, true) == nil {
		t.Fatal("logged out write accepted")
	}
	if p.FollowForum(context.Background(), "golang", true) == nil {
		t.Fatal("logged out forum write accepted")
	}
	p.session = sessionData{BDUSS: "credential", TBS: "token", UserID: "42"}
	for _, ref := range []domain.ProfileRef{ref, {Source: domain.SourceZhihu, ID: "17"}, {Source: domain.SourceTieba, ID: "0"}} {
		if p.Follow(context.Background(), ref, true) == nil {
			t.Fatal("invalid author accepted")
		}
	}
}
