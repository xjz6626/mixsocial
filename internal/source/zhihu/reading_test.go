package zhihu

import (
	"context"
	"github.com/xjz6626/mixsocial/internal/domain"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestQuestionAnswersAndDeferredComments(t *testing.T) {
	var commentRequests atomic.Int32
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v4/questions/7/answers":
			offset := r.URL.Query().Get("offset")
			id := 42
			if offset == "5" {
				id = 43
			}
			writeTestJSON(t, w, map[string]any{"data": []any{map[string]any{"id": id, "content": "<p>独立回答</p>", "question": map[string]any{"id": 7, "title": "问题标题"}, "author": map[string]any{"id": "a", "name": "作者"}}}, "paging": map[string]any{"is_end": offset == "5", "next": server.URL + "/api/v4/questions/7/answers?offset=5"}})
		case "/api/v4/answers/42":
			writeTestJSON(t, w, map[string]any{"id": 42, "type": "answer", "question": map[string]any{"id": 7, "title": "问题标题"}, "content": "<h2>标题</h2><p>独立正文</p><img src=\"https://pic.zhimg.com/a.jpg\">"})
		default:
			if strings.Contains(r.URL.Path, "comment_v5") {
				commentRequests.Add(1)
				http.Error(w, "unavailable", 503)
				return
			}
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	p := New(Config{Client: server.Client(), Endpoints: testEndpoints(server.URL)})
	ref := domain.Ref{Source: domain.SourceZhihu, ID: "7", Kind: "question"}
	question, err := p.Content(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	if len(question.Answers) != 1 || !question.AnswersHasMore || question.AnswersNextCursor != "5" || !question.CommentsPending {
		t.Fatalf("question: %+v", question)
	}
	if strings.Contains(question.Body, "独立回答") {
		t.Fatal("answers were flattened into question body")
	}
	answer := question.Answers[0]
	if answer.Ref.Kind != "answer" || answer.Ref.ParentID != "7" {
		t.Fatalf("answer identity: %+v", answer.Ref)
	}
	page, err := p.Answers(context.Background(), ref, question.AnswersNextCursor)
	if err != nil {
		t.Fatal(err)
	}
	if page.HasMore || page.Items[0].Ref.ID != "43" {
		t.Fatalf("answers page: %+v", page)
	}
	detail, err := p.Content(context.Background(), answer.Ref)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(detail.ContentHTML, "<h2>") || !detail.CommentsPending || commentRequests.Load() != 0 {
		t.Fatalf("body waited for comments: %+v", detail)
	}
	combined, err := p.Detail(context.Background(), answer.Ref)
	if err != nil {
		t.Fatal(err)
	}
	if combined.CommentsError == "" || combined.Body == "" {
		t.Fatalf("comment failure lost article: %+v", combined)
	}
}
