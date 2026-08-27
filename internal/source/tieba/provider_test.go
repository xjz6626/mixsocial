package tieba

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) { return f(request) }

func TestEncodeThreadsRequest(t *testing.T) {
	root, err := parseFields(encodeThreadsRequest("golang", 2, 20, 3))
	if err != nil {
		t.Fatal(err)
	}
	data, err := parseFields(firstBytes(root, 1))
	if err != nil {
		t.Fatal(err)
	}
	if got := firstString(data, 1); got != "golang" {
		t.Fatalf("forum = %q", got)
	}
	if got := firstUint(data, 15); got != 2 {
		t.Fatalf("page = %d", got)
	}
	if got := firstUint(data, 47); got != 3 {
		t.Fatalf("sort = %d", got)
	}
	common, _ := parseFields(firstBytes(data, 39))
	if firstUint(common, 1) != 2 || firstString(common, 2) != legacyVersion {
		t.Fatalf("bad common fields: %+v", common)
	}
}

func TestSearchRequestAndResponse(t *testing.T) {
	content := appendString(nil, 2, "hello from protobuf")
	user := appendUint(nil, 2, 42)
	user = appendString(user, 4, "tester")
	thread := appendUint(nil, 1, 12345)
	thread = appendString(thread, 3, "A thread")
	thread = appendUint(thread, 4, 7)
	thread = appendUint(thread, 56, 42)
	thread = appendBytes(thread, 142, content)
	pageFields := appendUint(nil, 6, 1)
	data := appendBytes(nil, 4, pageFields)
	data = appendBytes(data, 7, thread)
	data = appendBytes(data, 17, user)
	response := appendBytes(nil, 1, nil)
	response = appendBytes(response, 2, data)

	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("x_bd_data_type") != "protobuf" {
			t.Errorf("missing protobuf header")
		}
		reader, err := r.MultipartReader()
		if err != nil {
			t.Fatal(err)
		}
		part, err := reader.NextPart()
		if err != nil {
			t.Fatal(err)
		}
		requestBody, _ := io.ReadAll(part)
		if len(requestBody) == 0 {
			t.Error("empty protobuf request")
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(bytes.NewReader(response)),
			Request:    r,
		}, nil
	})}

	provider := New(Config{FRSURL: "http://tieba.test/frs", Client: client})
	page, err := provider.Search(context.Background(), "golang吧", "2")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.Items[0].Title != "A thread" || page.Items[0].Summary != "hello from protobuf" || page.Items[0].Author.Name != "tester" {
		t.Fatalf("unexpected page: %+v", page)
	}
	if page.Items[0].Author.Ref.Source != "tieba" || page.Items[0].Author.Ref.ID != "42" || page.Items[0].Author.Ref.URL == "" {
		t.Fatalf("unexpected author profile ref: %+v", page.Items[0].Author.Ref)
	}
	if !page.HasMore || page.NextCursor != "3" {
		t.Fatalf("unexpected cursor: %+v", page)
	}
}

func TestParseFieldsRejectsTruncation(t *testing.T) {
	if _, err := parseFields([]byte{0x0a, 0x05, 0x01}); err == nil {
		t.Fatal("expected truncation error")
	}
}

func TestDecodeContentsMapsImagesAndVideo(t *testing.T) {
	imageContent := appendUint(nil, 1, 3)
	imageContent = appendString(imageContent, 2, "with image")
	imageContent = appendString(imageContent, 25, "https://img.example/original.jpg")
	imageContent = appendUint(imageContent, 18, 640)
	imageContent = appendUint(imageContent, 19, 480)
	videoContent := appendUint(nil, 1, 5)
	videoContent = appendString(videoContent, 3, "https://video.example/clip.mp4")
	videoContent = appendString(videoContent, 4, "https://img.example/cover.jpg")
	videoContent = appendUint(videoContent, 13, 9)
	videoContent = appendUint(videoContent, 18, 720)
	videoContent = appendUint(videoContent, 19, 1280)

	text, media := decodeContents([][]byte{imageContent, videoContent})
	if text != "with image" || len(media) != 2 {
		t.Fatalf("unexpected decoded contents: text=%q media=%+v", text, media)
	}
	if media[0].Kind != "image" || media[0].PreviewURL == "" || media[1].Kind != "video" || media[1].PreviewURL == "" || media[1].Duration != 9*time.Second {
		t.Fatalf("unexpected media mapping: %+v", media)
	}
}
