package mobilecore

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestNewTiebaRejectsInvalidTimeout(t *testing.T) {
	if _, err := NewTieba(`{"timeout":"later"}`); err == nil {
		t.Fatal("expected invalid timeout error")
	}
}

func TestCancelRequest(t *testing.T) {
	core, err := NewTieba(`{"timeout":"10s"}`)
	if err != nil {
		t.Fatal(err)
	}
	ctx, finish := core.begin("request-1")
	defer finish()
	core.Cancel("request-1")
	select {
	case <-ctx.Done():
		if err := ctx.Err(); err != context.Canceled {
			t.Fatalf("expected cancellation, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("request was not cancelled")
	}
}

func TestDuplicateRequestCancelsPrevious(t *testing.T) {
	core, err := NewTieba(`{"timeout":"10s"}`)
	if err != nil {
		t.Fatal(err)
	}
	first, finishFirst := core.begin("same")
	defer finishFirst()
	second, finishSecond := core.begin("same")
	defer finishSecond()
	select {
	case <-first.Done():
	case <-time.After(time.Second):
		t.Fatal("replaced request was not cancelled")
	}
	if second.Err() != nil {
		t.Fatalf("replacement request unexpectedly ended: %v", second.Err())
	}
}

func TestDomainJSONUsesMobileFieldNames(t *testing.T) {
	core, err := NewTieba(`{"forums":["golang"],"timeout":"1s"}`)
	if err != nil {
		t.Fatal(err)
	}
	if core.timeout.String() != "1s" || len(core.forums) != 1 {
		t.Fatalf("unexpected core config: %+v", core)
	}
	encoded, err := json.Marshal(struct {
		NextCursor string `json:"nextCursor"`
	}{NextCursor: "2"})
	if err != nil || string(encoded) != `{"nextCursor":"2"}` {
		t.Fatalf("unexpected mobile JSON: %s, %v", encoded, err)
	}
}
