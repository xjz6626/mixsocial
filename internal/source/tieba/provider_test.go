package tieba

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
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

func TestEncodePostsRequestOptions(t *testing.T) {
	root, err := parseFields(encodePostsRequest(12345, 3, 30, true, true))
	if err != nil {
		t.Fatal(err)
	}
	data, err := parseFields(firstBytes(root, 1))
	if err != nil {
		t.Fatal(err)
	}
	if firstUint(data, 4) != 12345 || firstUint(data, 18) != 3 || firstUint(data, 13) != 30 {
		t.Fatalf("unexpected page request: %+v", data)
	}
	if firstUint(data, 5) != 1 || firstUint(data, 6) != 1 {
		t.Fatalf("missing only-OP/reverse flags: %+v", data)
	}
	if firstUint(data, 8) != 1 || firstUint(data, 9) != 3 {
		t.Fatalf("missing floor preview flags: %+v", data)
	}
}

func TestEncodeFloorRepliesRequest(t *testing.T) {
	root, err := parseFields(encodeFloorRepliesRequest(12345, 200, 99, 3))
	if err != nil {
		t.Fatal(err)
	}
	data, err := parseFields(firstBytes(root, 1))
	if err != nil {
		t.Fatal(err)
	}
	if firstUint(data, 1) != 12345 || firstUint(data, 2) != 200 || firstUint(data, 4) != 3 || firstUint(data, 11) != 99 {
		t.Fatalf("unexpected floor request: %+v", data)
	}
	common, _ := parseFields(firstBytes(data, 9))
	if firstUint(common, 1) != 2 || firstString(common, 2) != legacyVersion {
		t.Fatalf("bad common fields: %+v", common)
	}
}

func TestForumRequestAndResponse(t *testing.T) {
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
	page, err := provider.searchForum(context.Background(), "golang", "2", 6)
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

func TestDecodeThreadMapsForumMediaAndStandaloneVideo(t *testing.T) {
	photo := appendUint(nil, 1, 3)
	photo = appendString(photo, 3, "http://tiebapic.baidu.com/preview.jpg")
	photo = appendString(photo, 15, "http://tiebapic.baidu.com/original.jpg")
	photo = appendUint(photo, 10, 1080)
	photo = appendUint(photo, 11, 1440)
	video := appendString(nil, 2, "http://video.tieba.baidu.com/clip.mp4")
	video = appendUint(video, 3, 12)
	video = appendUint(video, 4, 1920)
	video = appendUint(video, 5, 1080)
	video = appendString(video, 6, "http://tiebapic.baidu.com/cover.jpg")

	thread := appendUint(nil, 1, 12345)
	thread = appendString(thread, 3, "media thread")
	thread = appendBytes(thread, 22, photo)
	thread = appendBytes(thread, 79, video)
	item, err := decodeThread(thread, "golang")
	if err != nil {
		t.Fatal(err)
	}
	if len(item.Media) != 2 {
		t.Fatalf("unexpected media: %+v", item.Media)
	}
	if got := item.Media[0]; got.Kind != "image" || got.URL != "https://tiebapic.baidu.com/original.jpg" || got.PreviewURL != "https://tiebapic.baidu.com/preview.jpg" || got.Width != 1080 || got.Height != 1440 {
		t.Fatalf("unexpected photo: %+v", got)
	}
	if got := item.Media[1]; got.Kind != "video" || got.URL != "https://video.tieba.baidu.com/clip.mp4" || got.PreviewURL != "https://tiebapic.baidu.com/cover.jpg" || got.Duration != 12*time.Second {
		t.Fatalf("unexpected video: %+v", got)
	}
}

func TestDecodePostMapsStandaloneVideoInfo(t *testing.T) {
	video := appendString(nil, 2, "http://video.tieba.baidu.com/floor.mp4")
	video = appendString(video, 6, "http://tiebapic.baidu.com/floor-cover.jpg")
	video = appendUint(video, 7, 720)
	video = appendUint(video, 8, 1280)
	post := appendUint(nil, 1, 99)
	post = appendBytes(post, 29, video)

	comment, err := decodePost(post, domain.Ref{Source: domain.SourceTieba, ID: "12345"})
	if err != nil {
		t.Fatal(err)
	}
	if len(comment.Media) != 1 {
		t.Fatalf("unexpected media: %+v", comment.Media)
	}
	got := comment.Media[0]
	if got.Kind != "video" || got.URL != "https://video.tieba.baidu.com/floor.mp4" || got.PreviewURL != "https://tiebapic.baidu.com/floor-cover.jpg" || got.Width != 720 || got.Height != 1280 {
		t.Fatalf("unexpected video: %+v", got)
	}
}

func TestAppendUniqueMediaMergesPreviewAndAlternateVideoTranscodes(t *testing.T) {
	media := appendUniqueMedia(nil,
		domain.Media{Kind: "image", URL: "https://img.example/photo.jpg", PreviewURL: "https://img.example/photo.jpg", Width: 640},
		domain.Media{Kind: "image", URL: "https://img.example/photo.jpg", PreviewURL: "https://img.example/preview.jpg", Height: 480},
		domain.Media{Kind: "video", URL: "https://video.example/transcode.mp4"},
		domain.Media{Kind: "video", URL: "https://video.example/original.mp4", PreviewURL: "https://img.example/cover.jpg"},
	)
	if len(media) != 2 {
		t.Fatalf("unexpected merged media: %+v", media)
	}
	if media[0].PreviewURL != "https://img.example/preview.jpg" || media[0].Width != 640 || media[0].Height != 480 {
		t.Fatalf("unexpected merged image: %+v", media[0])
	}
	if media[1].URL != "https://video.example/transcode.mp4" || media[1].PreviewURL != "https://img.example/cover.jpg" {
		t.Fatalf("unexpected merged video: %+v", media[1])
	}
}

func TestGlobalSearchRequestAndResponse(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodGet || r.URL.Path != "/mo/q/search/thread" {
			t.Fatalf("unexpected search request: %s %s", r.Method, r.URL)
		}
		if got := r.URL.Query().Get("word"); got != "golang" {
			t.Errorf("word = %q", got)
		}
		if got := r.URL.Query().Get("pn"); got != "2" {
			t.Errorf("pn = %q", got)
		}
		if r.Header.Get("Referer") == "" {
			t.Error("missing search referer")
		}
		if r.Header.Get("Cookie") != "" {
			t.Error("public search must not send account cookies")
		}
		body := `{"no":0,"error":"success","data":{"has_more":1,"current_page":2,"post_list":[{"tid":"12345","pid":678,"title":"A global result","content":"matched body","time":1700000000,"modified_time":"1700000123","user":{"user_name":"tester","show_nickname":"Test User","user_id":42,"portrait":"https://example.invalid/avatar.jpg"},"post_num":"7","like_num":12,"share_num":"3","forum_name":"golang","pb_url":"https://tieba.baidu.com/p/12345","media":[{"type":"pic","width":"640","height":480,"small_pic":"https://example.invalid/small.jpg","big_pic":"https://example.invalid/big.jpg"}] }]}}`
		return jsonHTTPResponse(r, body), nil
	})}

	provider := New(Config{SearchURL: "https://tieba.test/mo/q/search/thread", Client: client})
	page, err := provider.Search(context.Background(), " golang ", "2")
	if err != nil {
		t.Fatal(err)
	}
	if !page.HasMore || page.NextCursor != "3" || len(page.Items) != 1 {
		t.Fatalf("unexpected page: %+v", page)
	}
	item := page.Items[0]
	if item.Ref.ID != "12345" || item.Ref.ParentID != "678" || item.Title != "A global result" || item.Summary != "matched body" {
		t.Fatalf("unexpected item: %+v", item)
	}
	if item.Author.ID != "42" || item.Author.Name != "Test User" || item.Stats.Comments != 7 || item.Stats.Likes != 12 || item.Stats.Shares != 3 {
		t.Fatalf("unexpected metadata: %+v", item)
	}
	if len(item.Media) != 1 || item.Media[0].URL == "" || item.Media[0].Width != 640 {
		t.Fatalf("unexpected media: %+v", item.Media)
	}
	if item.PublishedAt.Unix() != 1700000123 || len(item.Tags) != 1 || item.Tags[0] != "golang吧" {
		t.Fatalf("unexpected context: %+v", item)
	}
}

func TestForumSearchNarrowsPublicSearch(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Query().Get("fname") != "golang" || r.URL.Query().Get("ct") != "2" {
			t.Fatalf("unexpected forum search query: %s", r.URL.RawQuery)
		}
		if r.URL.Query().Has("is_use_zonghe") {
			t.Fatalf("forum search must disable aggregate mode: %s", r.URL.RawQuery)
		}
		return jsonHTTPResponse(r, `{"no":0,"error":"success","data":{"has_more":0,"post_list":[]}}`), nil
	})}
	provider := New(Config{SearchURL: "https://tieba.test/mo/q/search/thread", Client: client})
	page, err := provider.SearchForumThreads(context.Background(), "golang吧", " generics ", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 0 || page.HasMore {
		t.Fatalf("unexpected page: %+v", page)
	}
}

func TestDecodePostsResponseIncludesPaginationAndFloorReplies(t *testing.T) {
	user := appendUint(nil, 2, 42)
	user = appendString(user, 4, "楼主")
	mainContent := appendString(nil, 2, "主楼正文")
	mainPost := appendUint(nil, 1, 100)
	mainPost = appendUint(mainPost, 3, 1)
	mainPost = appendUint(mainPost, 19, 42)
	mainPost = appendBytes(mainPost, 5, mainContent)
	mainPost = appendBytes(mainPost, 23, user)

	replyUser := appendUint(nil, 2, 84)
	replyUser = appendString(replyUser, 4, "回复者")
	subContent := appendString(nil, 2, "楼中楼")
	sub := appendUint(nil, 1, 300)
	sub = appendBytes(sub, 2, subContent)
	sub = appendUint(sub, 3, 1700000200)
	sub = appendUint(sub, 4, 84)
	sub = appendBytes(sub, 7, replyUser)
	subAgree := appendUint(nil, 1, 2)
	sub = appendBytes(sub, 9, subAgree)
	subContainer := appendBytes(nil, 2, sub)

	replyContent := appendString(nil, 2, "二楼正文")
	reply := appendUint(nil, 1, 200)
	reply = appendUint(reply, 3, 2)
	reply = appendUint(reply, 4, 1700000100)
	reply = appendBytes(reply, 5, replyContent)
	reply = appendUint(reply, 13, 3)
	reply = appendBytes(reply, 15, subContainer)
	reply = appendUint(reply, 19, 84)
	reply = appendBytes(reply, 23, replyUser)
	replyAgree := appendUint(nil, 1, 9)
	reply = appendBytes(reply, 37, replyAgree)

	thread := appendUint(nil, 1, 12345)
	thread = appendString(thread, 3, "分页主题")
	thread = appendBytes(thread, 18, user)
	pageFields := appendUint(nil, 3, 1)
	pageFields = appendUint(pageFields, 6, 1)
	data := appendBytes(nil, 3, pageFields)
	data = appendBytes(data, 6, mainPost)
	data = appendBytes(data, 6, reply)
	data = appendBytes(data, 8, thread)
	data = appendBytes(data, 13, user)
	data = appendBytes(data, 13, replyUser)
	response := appendBytes(nil, 2, data)

	ref := domain.Ref{Source: domain.SourceTieba, ID: "12345", URL: "https://tieba.baidu.com/p/12345"}
	detail, err := decodePostsResponse(response, ref, 1)
	if err != nil {
		t.Fatal(err)
	}
	if detail.Body != "主楼正文" || !detail.HasMore || detail.NextCursor != "2" {
		t.Fatalf("unexpected detail header: %+v", detail)
	}
	if len(detail.Comments) != 1 {
		t.Fatalf("unexpected comments: %+v", detail.Comments)
	}
	comment := detail.Comments[0]
	if comment.Floor != 2 || comment.Likes != 9 || comment.ReplyCount != 3 || len(comment.Replies) != 1 {
		t.Fatalf("unexpected floor: %+v", comment)
	}
	if comment.Replies[0].Body != "楼中楼" || comment.Replies[0].Likes != 2 || comment.Replies[0].Ref.ParentID != "200" {
		t.Fatalf("unexpected sub-post: %+v", comment.Replies[0])
	}
}

func TestDecodeFloorRepliesResponse(t *testing.T) {
	author := appendUint(nil, 2, 84)
	author = appendString(author, 4, "回复者")
	content := appendString(nil, 2, "完整楼中楼")
	reply := appendUint(nil, 1, 300)
	reply = appendBytes(reply, 2, content)
	reply = appendUint(reply, 3, 1700000200)
	reply = appendUint(reply, 4, 84)
	reply = appendUint(reply, 6, 2)
	reply = appendBytes(reply, 7, author)
	agree := appendUint(nil, 1, 7)
	reply = appendBytes(reply, 9, agree)
	pageFields := appendUint(nil, 3, 1)
	pageFields = appendUint(pageFields, 6, 1)
	data := appendBytes(nil, 1, pageFields)
	data = appendBytes(data, 4, reply)
	response := appendBytes(nil, 2, data)

	floorRef := domain.Ref{
		Source: domain.SourceTieba, ID: "200", ParentID: "12345", Token: "99",
		URL: "https://tieba.baidu.com/p/12345",
	}
	page, err := decodeFloorRepliesResponse(response, floorRef, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !page.HasMore || page.NextCursor != "2" || len(page.Comments) != 1 {
		t.Fatalf("unexpected page: %+v", page)
	}
	comment := page.Comments[0]
	if comment.Body != "完整楼中楼" || comment.Floor != 2 || comment.Likes != 7 || comment.Ref.ParentID != "200" || comment.Ref.Token != "99" {
		t.Fatalf("unexpected reply: %+v", comment)
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

func TestDecodeContentsUsesTiebaImageFallbacksAndBsize(t *testing.T) {
	imageContent := appendUint(nil, 1, 3)
	imageContent = appendString(imageContent, 5, "1080,1440")
	imageContent = appendString(imageContent, 6, "https://img.example/big-src.jpg")

	_, media := decodeContents([][]byte{imageContent})
	if len(media) != 1 || media[0].URL != "https://img.example/big-src.jpg" {
		t.Fatalf("unexpected fallback media: %+v", media)
	}
	if media[0].Width != 1080 || media[0].Height != 1440 {
		t.Fatalf("unexpected dimensions: %+v", media[0])
	}
}

func TestTiebaAvatarURL(t *testing.T) {
	for _, test := range []struct {
		portrait string
		want     string
	}{
		{portrait: "tb.1.example", want: "https://himg.bdimg.com/sys/portrait/item/tb.1.example"},
		{portrait: "tb.1.example?t=1711009997", want: "https://himg.bdimg.com/sys/portrait/item/tb.1.example?t=1711009997"},
		{portrait: "//tb.himg.baidu.com/avatar.jpg?t=1", want: "https://himg.bdimg.com/avatar.jpg?t=1"},
		{portrait: "https://example.invalid/avatar.jpg", want: "https://example.invalid/avatar.jpg"},
	} {
		if got := tiebaAvatarURL(test.portrait); got != test.want {
			t.Fatalf("tiebaAvatarURL(%q) = %q, want %q", test.portrait, got, test.want)
		}
	}
}

func TestDecodeContentsUsesEmoticonLabelInsteadOfResourceName(t *testing.T) {
	emoticon := appendUint(nil, 1, 2)
	emoticon = appendString(emoticon, 2, "image_emoticon25")
	emoticon = appendString(emoticon, 11, "滑稽")

	text, media := decodeContents([][]byte{emoticon})
	if text != "#(滑稽)" || len(media) != 0 {
		t.Fatalf("unexpected emoticon decoding: text=%q media=%+v", text, media)
	}
}
