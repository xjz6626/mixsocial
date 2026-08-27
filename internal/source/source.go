package source

import (
	"context"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
)

type Capability uint32

const (
	CapabilityFeed Capability = 1 << iota
	CapabilitySearch
	CapabilityDetail
	CapabilityLike
	CapabilityFavorite
	CapabilityComment
	CapabilityReply
	CapabilityHot
	CapabilityFollowing
	CapabilityCredentialLogin
	CapabilityQRCodeLogin
	CapabilityFollow
	CapabilityBlock
)

func (c Capability) Has(want Capability) bool { return c&want != 0 }

// Reader intentionally has no publishing method. A source cannot accidentally
// grow publishing support through the common interface.
type Reader interface {
	ID() domain.SourceID
	Name() string
	Capabilities() Capability
	Feed(ctx context.Context, cursor string) (domain.Page, error)
	Search(ctx context.Context, query, cursor string) (domain.Page, error)
	Detail(ctx context.Context, ref domain.Ref) (domain.Detail, error)
}

// Channel is a first-class home timeline. Search remains separate because it
// needs a query and has different semantics on the two sites.
type Channel string

const (
	ChannelRecommend Channel = "recommend"
	ChannelHot       Channel = "hot"
	ChannelFollowing Channel = "following"
)

func (c Channel) Label() string {
	switch c {
	case ChannelRecommend:
		return "推荐"
	case ChannelHot:
		return "热榜"
	case ChannelFollowing:
		return "关注"
	default:
		return string(c)
	}
}

// ChannelReader is optional so a simple Reader can still participate in the
// recommendation feed. Mixed falls back to Reader.Feed for recommend only.
type ChannelReader interface {
	Browse(ctx context.Context, channel Channel, cursor string) (domain.Page, error)
}

type Interactor interface {
	Like(ctx context.Context, ref domain.Ref, value bool) error
	Favorite(ctx context.Context, ref domain.Ref, value bool) error
	Comment(ctx context.Context, ref domain.Ref, body string) error
	Reply(ctx context.Context, ref domain.Ref, comment domain.Ref, body string) error
}

// RelationshipInteractor changes the relationship with an account. Follow
// and Block are kept separate from content interactions because sources may
// support one without the other, or implement them through a mobile WebView
// while content reading remains a native HTTP adapter.
type RelationshipInteractor interface {
	Follow(ctx context.Context, profile domain.ProfileRef, value bool) error
	Block(ctx context.Context, profile domain.ProfileRef, value bool) error
}

type LoginStatus struct {
	LoggedIn bool
	Username string
	UserID   string
}

type LoginChallenge struct {
	LoggedIn bool
	Image    []byte
	Timeout  time.Duration
}

// Authenticator is optional and deliberately separate from Reader. Login is
// session setup, not a content action, and credentials remain source-owned.
type Authenticator interface {
	LoginStatus(ctx context.Context) (LoginStatus, error)
	LoginQRCode(ctx context.Context) (LoginChallenge, error)
}

// CredentialAuthenticator is used by sources whose established login flow is
// importing an existing session credential. The TUI masks it and the provider
// owns validation and persistence; account passwords never enter mixsocial.
type CredentialAuthenticator interface {
	LoginStatus(ctx context.Context) (LoginStatus, error)
	LoginWithCredential(ctx context.Context, credential string) (LoginStatus, error)
}
