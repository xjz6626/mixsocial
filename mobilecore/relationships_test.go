package mobilecore

import "testing"

func TestRelationshipBridgeRejectsMalformedCrossSourceAndAnonymousRefs(t *testing.T) {
	tieba, err := NewTieba("")
	if err != nil {
		t.Fatal(err)
	}
	defer tieba.Close()
	zhihu, err := NewZhihu("")
	if err != nil {
		t.Fatal(err)
	}
	defer zhihu.Close()
	for _, ref := range []string{`{}`, `invalid`, `{"source":"xhs","id":"42"}`, `{"source":"tieba","id":"0"}`} {
		if err := tieba.FollowWithRequest("test", ref, true); err == nil {
			t.Fatal("invalid Tieba follow accepted")
		}
		if _, err := tieba.FollowingWithRequest("test", ref); err == nil {
			t.Fatal("invalid Tieba state query accepted")
		}
	}
	for _, ref := range []string{`{}`, `{"source":"tieba","id":"42"}`, `{"source":"zhihu","id":"0"}`} {
		if err := zhihu.FollowWithRequest("test", ref, false); err == nil {
			t.Fatal("invalid Zhihu follow accepted")
		}
		if _, err := zhihu.FollowingWithRequest("test", ref); err == nil {
			t.Fatal("invalid Zhihu state query accepted")
		}
	}
}
