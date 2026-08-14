package source

import (
	"context"
	"errors"
	"testing"

	"github.com/xjz6626/mixsocial/internal/domain"
)

type stubReader struct {
	id    domain.SourceID
	items []domain.Item
	err   error
}

func (s stubReader) ID() domain.SourceID      { return s.id }
func (s stubReader) Name() string             { return string(s.id) }
func (s stubReader) Capabilities() Capability { return CapabilityFeed | CapabilitySearch }
func (s stubReader) Feed(context.Context, string) (domain.Page, error) {
	return domain.Page{Items: s.items}, s.err
}
func (s stubReader) Search(context.Context, string, string) (domain.Page, error) {
	return domain.Page{Items: s.items}, s.err
}
func (s stubReader) Detail(context.Context, domain.Ref) (domain.Detail, error) {
	return domain.Detail{}, errors.New("unused")
}

func TestMixedRoundRobinAndPartialFailure(t *testing.T) {
	a := stubReader{id: domain.SourceTieba, items: []domain.Item{{Title: "a1"}, {Title: "a2"}}}
	b := stubReader{id: domain.SourceXHS, items: []domain.Item{{Title: "b1"}, {Title: "b2"}}}
	page, err := NewMixed(a, b).Feed(context.Background(), "", "")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"a1", "b1", "a2", "b2"}
	for i, title := range want {
		if page.Items[i].Title != title {
			t.Fatalf("item %d = %q, want %q", i, page.Items[i].Title, title)
		}
	}

	broken := stubReader{id: domain.SourceXHS, err: errors.New("offline")}
	page, err = NewMixed(a, broken).Feed(context.Background(), "", "")
	if err != nil {
		t.Fatalf("partial result should not fail: %v", err)
	}
	if len(page.Items) != 2 || len(page.Notices) != 1 {
		t.Fatalf("unexpected partial page: %+v", page)
	}
}
