package tieba

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sync"
	"testing"
)

func TestForumBatchesRotateBeyondEightAndAdvancePages(t *testing.T) {
	var mu sync.Mutex
	requests := map[string][]uint64{}
	forums := []string{}
	for i := 0; i < 10; i++ {
		forums = append(forums, fmt.Sprintf("forum-%d", i))
	}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		reader, err := r.MultipartReader()
		if err != nil {
			return nil, err
		}
		part, err := reader.NextPart()
		if err != nil {
			return nil, err
		}
		body, _ := io.ReadAll(part)
		root, _ := parseFields(body)
		fields, _ := parseFields(firstBytes(root, 1))
		name, number := firstString(fields, 1), firstUint(fields, 15)
		if number == 0 {
			number = 1
		} // Protobuf omits the default first page.
		mu.Lock()
		requests[name] = append(requests[name], number)
		mu.Unlock()
		// The first batch has another page; the second does not. Its empty end
		// must not erase the carry bit from the earlier forums.
		more := uint64(0)
		if name == "forum-0" && number == 1 {
			more = 1
		}
		pageFields := appendUint(nil, 6, more)
		data := appendBytes(nil, 4, pageFields)
		return protoHTTPResponse(r, appendBytes(nil, 2, data)), nil
	})}
	p := New(Config{Forums: forums, FRSURL: "https://tieba.test/frs", Client: client})
	first, err := p.Browse(context.Background(), "recommend", "")
	if err != nil {
		t.Fatal(err)
	}
	if !first.HasMore || first.NextCursor != "forums:1:8:true" || len(requests) != 8 {
		t.Fatalf("first batch: %+v, requests: %v", first, requests)
	}
	second, err := p.Browse(context.Background(), "recommend", first.NextCursor)
	if err != nil {
		t.Fatal(err)
	}
	if !second.HasMore || second.NextCursor != "forums:2:0:false" || len(requests) != 10 {
		t.Fatalf("second batch: %+v, requests: %v", second, requests)
	}
	third, err := p.Browse(context.Background(), "recommend", second.NextCursor)
	if err != nil {
		t.Fatal(err)
	}
	fourth, err := p.Browse(context.Background(), "recommend", third.NextCursor)
	if err != nil {
		t.Fatal(err)
	}
	if fourth.HasMore {
		t.Fatalf("ended forums still have more: %+v", fourth)
	}
	for name, pages := range requests {
		if len(pages) != 2 || pages[0] != 1 || pages[1] != 2 {
			t.Errorf("%s pages = %v", name, pages)
		}
	}
}
