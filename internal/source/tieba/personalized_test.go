package tieba

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestRecommendUsesOfficialPersonalizedFeed(t *testing.T) {
	requests := 0
	bduss := strings.Repeat("b", 192)
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		requests++
		if request.URL.Path != "/c/f/excellent/personalized" || request.URL.Query().Get("cmd") != "309264" {
			t.Fatalf("recommendation used an unexpected endpoint: %s", request.URL)
		}
		if request.Header.Get("client_user_token") != "42" || request.Header.Get("x_bd_data_type") != "protobuf" {
			t.Fatalf("missing recommendation headers: %+v", request.Header)
		}
		if !strings.Contains(request.Header.Get("User-Agent"), "tieba/"+personalizedVersion) {
			t.Fatalf("unexpected recommendation user agent: %q", request.Header.Get("User-Agent"))
		}

		reader, err := request.MultipartReader()
		if err != nil {
			t.Fatal(err)
		}
		var protoBody []byte
		var stoken string
		for {
			part, partErr := reader.NextPart()
			if partErr == io.EOF {
				break
			}
			if partErr != nil {
				t.Fatal(partErr)
			}
			encoded, readErr := io.ReadAll(part)
			if readErr != nil {
				t.Fatal(readErr)
			}
			switch part.FormName() {
			case "data":
				protoBody = encoded
			case "stoken":
				stoken = string(encoded)
			}
		}
		if stoken != "stoken-value" {
			t.Fatalf("stoken multipart field = %q", stoken)
		}

		root, err := parseFields(protoBody)
		if err != nil {
			t.Fatal(err)
		}
		data, err := parseFields(firstBytes(root, 1))
		if err != nil {
			t.Fatal(err)
		}
		wantLoadType := uint64(1)
		if requests > 1 {
			wantLoadType = 2
		}
		if firstUint(data, 4) != wantLoadType || firstUint(data, 5) != personalizedPageSize || firstUint(data, 6) != uint64(requests) {
			t.Fatalf("unexpected recommendation paging fields: %+v", data)
		}
		common, err := parseFields(firstBytes(data, 1))
		if err != nil {
			t.Fatal(err)
		}
		if firstString(common, 2) != personalizedVersion || firstString(common, 10) != bduss || firstString(common, 30) != "stoken-value" {
			t.Fatalf("unexpected recommendation common fields: %+v", common)
		}

		return protoHTTPResponse(request, personalizedTestResponse()), nil
	})}

	provider := New(Config{
		Client:       client,
		RecommendURL: "https://tieba.test/c/f/excellent/personalized?cmd=309264",
		FollowURL:    "https://tieba.test/follow-must-not-be-used",
	})
	provider.session = sessionData{BDUSS: bduss, STOKEN: "stoken-value", UserID: "42"}

	page, err := provider.Browse(context.Background(), "recommend", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || !page.HasMore || page.NextCursor != "2" {
		t.Fatalf("unexpected first recommendation page: %+v", page)
	}
	item := page.Items[0]
	if item.Ref.ID != "12345" || item.Title != "A personalized thread" || item.Summary != "recommended body" {
		t.Fatalf("unexpected recommendation item: %+v", item)
	}
	if item.Author.Name != "tester" || item.Stats.Likes != 9 || len(item.Tags) != 1 || item.Tags[0] != "golang吧" {
		t.Fatalf("unexpected recommendation metadata: %+v", item)
	}

	page, err = provider.Browse(context.Background(), "recommend", "2")
	if err != nil {
		t.Fatal(err)
	}
	if page.NextCursor != "3" || requests != 2 {
		t.Fatalf("unexpected second recommendation page: requests=%d page=%+v", requests, page)
	}
}

func personalizedTestResponse() []byte {
	author := appendUint(nil, 2, 42)
	author = appendString(author, 4, "tester")
	richAbstract := appendString(nil, 2, "recommended body")
	forum := appendUint(nil, 1, 99)
	forum = appendString(forum, 2, "golang")

	thread := appendUint(nil, 1, 12345)
	thread = appendString(thread, 3, "A personalized thread")
	thread = appendUint(thread, 4, 7)
	thread = appendUint(thread, 5, 120)
	thread = appendBytes(thread, 18, author)
	thread = appendBytes(thread, 112, richAbstract)
	thread = appendUint(thread, 124, 9)
	thread = appendBytes(thread, 155, forum)

	liveThread := appendUint(nil, 1, 54321)
	liveThread = appendString(liveThread, 3, "A live room")
	liveThread = appendBytes(liveThread, 113, appendUint(nil, 1, 1))

	data := appendBytes(nil, 2, thread)
	data = appendBytes(data, 2, liveThread)
	return appendBytes(nil, 2, data)
}

func protoHTTPResponse(request *http.Request, body []byte) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     make(http.Header),
		Body:       io.NopCloser(bytes.NewReader(body)),
		Request:    request,
	}
}
