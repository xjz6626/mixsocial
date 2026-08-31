package tieba

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/xjz6626/mixsocial/internal/source"
)

func TestLoginWithCredentialValidatesAndPersists(t *testing.T) {
	bduss := strings.Repeat("a", 192)
	sessionPath := filepath.Join(t.TempDir(), "private", "tieba-session.json")
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/login" {
			t.Fatalf("unexpected path %s", request.URL.Path)
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatal(err)
		}
		values, err := url.ParseQuery(string(body))
		if err != nil {
			t.Fatal(err)
		}
		if values.Get("bdusstoken") != bduss || values.Get("_client_version") != latestVersion {
			t.Fatalf("unexpected login form keys: %v", values)
		}
		sum := md5.Sum([]byte("_client_version=" + latestVersion + "bdusstoken=" + bduss + appSalt))
		if values.Get("sign") != hex.EncodeToString(sum[:]) {
			t.Fatalf("bad Tieba signature %q", values.Get("sign"))
		}
		return jsonHTTPResponse(request, `{"error_code":"0","user":{"id":"42","name":"alice"},"anti":{"tbs":"tbs-token"}}`), nil
	})}

	provider := New(Config{Client: client, LoginURL: "https://tieba.test/login", SessionPath: sessionPath})
	status, err := provider.LoginWithCredential(context.Background(), "BDUSS="+bduss+"; STOKEN=stoken-value")
	if err != nil {
		t.Fatal(err)
	}
	if !status.LoggedIn || status.Username != "alice" || status.UserID != "42" {
		t.Fatalf("unexpected status: %+v", status)
	}
	info, err := os.Stat(sessionPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("session mode = %o", got)
	}
	reloaded := New(Config{Client: client, LoginURL: "https://tieba.test/login", SessionPath: sessionPath})
	session, err := reloaded.sessionSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if session.BDUSS != bduss || session.STOKEN != "stoken-value" || session.TBS != "tbs-token" {
		t.Fatalf("session was not reloaded: %+v", session)
	}
}

func TestFollowingAndHotChannels(t *testing.T) {
	threadResponse := testThreadResponse()
	var mutex sync.Mutex
	var sorts []uint64
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/follow" {
			if !strings.Contains(request.Header.Get("Cookie"), "BDUSS=") || request.Header.Get("Subapp-Type") != "hybrid" {
				t.Errorf("missing follow auth headers")
			}
			return jsonHTTPResponse(request, `{"error_code":"0","like_forum":[{"forum_name":"golang"},{"forum_name":"linux"}],"like_forum_has_more":0}`), nil
		}
		if request.URL.Path == "/hot" {
			return jsonHTTPResponse(request, `{"errno":0,"errmsg":"success","data":{"bang_topic":{"topic_list":[{"topic_id":99,"topic_name":"Hot topic","topic_desc":"Hot body","topic_pic":"https://img.test/hot","discuss_num":1234,"idx_num":1,"create_time":1700000000,"topic_url":"https://tieba.baidu.com/hottopic?id=99&amp;from=list"}]}}}`), nil
		}
		reader, err := request.MultipartReader()
		if err != nil {
			t.Fatal(err)
		}
		part, err := reader.NextPart()
		if err != nil {
			t.Fatal(err)
		}
		encoded, _ := io.ReadAll(part)
		root, _ := parseFields(encoded)
		data, _ := parseFields(firstBytes(root, 1))
		mutex.Lock()
		sorts = append(sorts, firstUint(data, 47))
		mutex.Unlock()
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(threadResponse)), Request: request}, nil
	})}

	provider := New(Config{Client: client, FRSURL: "http://tieba.test/frs", FollowURL: "https://tieba.test/follow"})
	provider.session = sessionData{BDUSS: strings.Repeat("b", 192), STOKEN: "s", TBS: "tbs", UserID: "1"}
	page, err := provider.Browse(context.Background(), source.ChannelFollowing, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 2 || len(sorts) != 2 || sorts[0] != 6 || sorts[1] != 6 {
		t.Fatalf("unexpected following page/sorts: items=%d sorts=%v", len(page.Items), sorts)
	}

	mutex.Lock()
	sorts = nil
	mutex.Unlock()
	hot := New(Config{Client: client, FRSURL: "http://tieba.test/frs", HotURL: "https://tieba.test/hot", Forums: []string{"golang"}})
	hotPage, err := hot.Browse(context.Background(), source.ChannelHot, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(hotPage.Items) != 1 || hotPage.Items[0].Ref.Token != hotTopicToken || hotPage.Items[0].Stats.Comments != 1234 || len(sorts) != 0 {
		t.Fatalf("hot page = %+v, fallback sorts = %v", hotPage, sorts)
	}
	detail, err := hot.Detail(context.Background(), hotPage.Items[0].Ref)
	if err != nil || detail.Body != "Hot body" || strings.Contains(detail.Ref.URL, "&amp;") {
		t.Fatalf("hot detail = %+v, err = %v", detail, err)
	}
}

func TestFollowingForumsReadsEveryPage(t *testing.T) {
	var pages []string
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatal(err)
		}
		values, err := url.ParseQuery(string(body))
		if err != nil {
			t.Fatal(err)
		}
		page := values.Get("page_no")
		pages = append(pages, page)
		if page == "1" {
			return jsonHTTPResponse(request, `{"error_code":"0","like_forum":[{"forum_name":"golang"}],"like_forum_has_more":1}`), nil
		}
		return jsonHTTPResponse(request, `{"error_code":"0","like_forum":[{"forum_name":"linux"}],"like_forum_has_more":0}`), nil
	})}
	provider := New(Config{Client: client, FollowURL: "https://tieba.test/follow"})
	provider.session = sessionData{BDUSS: strings.Repeat("b", 192), TBS: "tbs", UserID: "1"}
	forums, err := provider.FollowingForums(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(pages, ",") != "1,2" || strings.Join(forums, ",") != "golang,linux" {
		t.Fatalf("pages=%v forums=%v", pages, forums)
	}
}

func jsonHTTPResponse(request *http.Request, body string) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
		Request:    request,
	}
}

func testThreadResponse() []byte {
	content := appendString(nil, 2, "summary")
	thread := appendUint(nil, 1, 12345)
	thread = appendString(thread, 3, "A thread")
	thread = appendBytes(thread, 142, content)
	data := appendBytes(nil, 7, thread)
	return appendBytes(nil, 2, data)
}
