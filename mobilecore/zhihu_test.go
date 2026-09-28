package mobilecore

import "testing"

func TestNewZhihuValidatesMobileConfig(t *testing.T) {
	if _, err := NewZhihu(`{"timeout":"later"}`); err == nil {
		t.Fatal("expected invalid timeout error")
	}
	if _, err := NewZhihu(`{"pageSize":31}`); err == nil {
		t.Fatal("expected invalid page size error")
	}
	core, err := NewZhihu(`{"timeout":"10s","pageSize":12}`)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(core.Close)
	if core.timeout.String() != "10s" || core.pageSize != 12 {
		t.Fatalf("unexpected config: timeout=%v pageSize=%d", core.timeout, core.pageSize)
	}
}

func TestZhihuRejectsCrossSourceAndEmptyRefs(t *testing.T) {
	core, err := NewZhihu(`{"timeout":"10s"}`)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(core.Close)
	for _, ref := range []string{`{}`, `{"source":"tieba","id":"42"}`} {
		if _, err := core.DetailWithRequest("", ref); err == nil {
			t.Fatalf("expected invalid ref error for %s", ref)
		}
	}
}
