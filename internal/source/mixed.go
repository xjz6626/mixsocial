package source

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/xjz6626/mixsocial/internal/domain"
)

type Mixed struct {
	readers map[domain.SourceID]Reader
	order   []domain.SourceID
}

func NewMixed(readers ...Reader) *Mixed {
	m := &Mixed{readers: make(map[domain.SourceID]Reader)}
	for _, reader := range readers {
		if reader == nil {
			continue
		}
		if _, exists := m.readers[reader.ID()]; !exists {
			m.order = append(m.order, reader.ID())
		}
		m.readers[reader.ID()] = reader
	}
	return m
}

func (m *Mixed) Sources() []Reader {
	out := make([]Reader, 0, len(m.order))
	for _, id := range m.order {
		out = append(out, m.readers[id])
	}
	return out
}

func (m *Mixed) Feed(ctx context.Context, sourceID domain.SourceID, cursor string) (domain.Page, error) {
	return m.Browse(ctx, sourceID, ChannelRecommend, cursor)
}

func (m *Mixed) Browse(ctx context.Context, sourceID domain.SourceID, channel Channel, cursor string) (domain.Page, error) {
	if sourceID != "" {
		reader, ok := m.readers[sourceID]
		if !ok {
			return domain.Page{}, fmt.Errorf("unknown source %q", sourceID)
		}
		return browse(ctx, reader, channel, cursor)
	}
	return m.collect(ctx, func(ctx context.Context, reader Reader) (domain.Page, error) {
		return browse(ctx, reader, channel, cursor)
	})
}

func browse(ctx context.Context, reader Reader, channel Channel, cursor string) (domain.Page, error) {
	if channelReader, ok := reader.(ChannelReader); ok {
		return channelReader.Browse(ctx, channel, cursor)
	}
	if channel == ChannelRecommend {
		return reader.Feed(ctx, cursor)
	}
	return domain.Page{}, fmt.Errorf("不支持%s频道", channel.Label())
}

func (m *Mixed) Search(ctx context.Context, sourceID domain.SourceID, query, cursor string) (domain.Page, error) {
	if sourceID != "" {
		reader, ok := m.readers[sourceID]
		if !ok {
			return domain.Page{}, fmt.Errorf("unknown source %q", sourceID)
		}
		return reader.Search(ctx, query, cursor)
	}
	return m.collect(ctx, func(ctx context.Context, reader Reader) (domain.Page, error) {
		return reader.Search(ctx, query, cursor)
	})
}

func (m *Mixed) Detail(ctx context.Context, ref domain.Ref) (domain.Detail, error) {
	reader, ok := m.readers[ref.Source]
	if !ok {
		return domain.Detail{}, fmt.Errorf("unknown source %q", ref.Source)
	}
	return reader.Detail(ctx, ref)
}

func (m *Mixed) Interactor(id domain.SourceID) (Interactor, bool) {
	reader, ok := m.readers[id]
	if !ok {
		return nil, false
	}
	interactor, ok := reader.(Interactor)
	return interactor, ok
}

func (m *Mixed) Authenticator(id domain.SourceID) (Authenticator, bool) {
	reader, ok := m.readers[id]
	if !ok {
		return nil, false
	}
	authenticator, ok := reader.(Authenticator)
	return authenticator, ok
}

func (m *Mixed) CredentialAuthenticator(id domain.SourceID) (CredentialAuthenticator, bool) {
	reader, ok := m.readers[id]
	if !ok {
		return nil, false
	}
	authenticator, ok := reader.(CredentialAuthenticator)
	return authenticator, ok
}

func (m *Mixed) Close() error {
	var errs []error
	for _, id := range m.order {
		if closer, ok := m.readers[id].(interface{ Close() error }); ok {
			if err := closer.Close(); err != nil {
				errs = append(errs, fmt.Errorf("close %s: %w", m.readers[id].Name(), err))
			}
		}
	}
	return errors.Join(errs...)
}

type sourceResult struct {
	id   domain.SourceID
	name string
	page domain.Page
	err  error
}

func (m *Mixed) collect(ctx context.Context, call func(context.Context, Reader) (domain.Page, error)) (domain.Page, error) {
	if len(m.order) == 0 {
		return domain.Page{}, errors.New("no sources configured")
	}

	results := make(chan sourceResult, len(m.order))
	for _, id := range m.order {
		reader := m.readers[id]
		go func() {
			page, err := call(ctx, reader)
			results <- sourceResult{id: reader.ID(), name: reader.Name(), page: page, err: err}
		}()
	}

	bySource := make(map[domain.SourceID][]domain.Item, len(m.order))
	var page domain.Page
	var errs []error
	successes := 0
	for range m.order {
		result := <-results
		if result.err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", result.name, result.err))
			page.Notices = append(page.Notices, result.name+"暂不可用: "+oneLine(result.err.Error()))
			continue
		}
		successes++
		bySource[result.id] = result.page.Items
		page.Notices = append(page.Notices, result.page.Notices...)
		page.HasMore = page.HasMore || result.page.HasMore
	}

	// Round-robin keeps one busy source from drowning out the other one.
	for index := 0; ; index++ {
		added := false
		for _, id := range m.order {
			items := bySource[id]
			if index < len(items) {
				page.Items = append(page.Items, items[index])
				added = true
			}
		}
		if !added {
			break
		}
	}

	if successes == 0 && len(errs) > 0 {
		sort.Strings(page.Notices)
		return page, errors.Join(errs...)
	}
	return page, nil
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
