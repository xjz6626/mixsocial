package domain

import "time"

type SourceID string

const (
	SourceTieba SourceID = "tieba"
	SourceXHS   SourceID = "xhs"
	SourceDemo  SourceID = "demo"
)

func (s SourceID) Label() string {
	switch s {
	case SourceTieba:
		return "贴吧"
	case SourceXHS:
		return "小红书"
	case SourceDemo:
		return "演示"
	default:
		return string(s)
	}
}

type Ref struct {
	Source   SourceID `json:"source"`
	ID       string   `json:"id"`
	ParentID string   `json:"parentId,omitempty"`
	Token    string   `json:"token,omitempty"`
	URL      string   `json:"url,omitempty"`
}

// ProfileRef identifies an account on one source. Token is source-owned and
// may be required when opening a profile through that source's web client.
// It is deliberately separate from Ref so content and account actions cannot
// accidentally be sent to the wrong endpoint.
type ProfileRef struct {
	Source SourceID `json:"source"`
	ID     string   `json:"id"`
	Token  string   `json:"token,omitempty"`
	URL    string   `json:"url,omitempty"`
}

type Author struct {
	Ref       ProfileRef `json:"ref"`
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Avatar    string     `json:"avatar,omitempty"`
	Following bool       `json:"following,omitempty"`
	Blocked   bool       `json:"blocked,omitempty"`
}

type Stats struct {
	Views     int64 `json:"views,omitempty"`
	Likes     int64 `json:"likes,omitempty"`
	Comments  int64 `json:"comments,omitempty"`
	Favorites int64 `json:"favorites,omitempty"`
	Shares    int64 `json:"shares,omitempty"`
}

type Media struct {
	Kind       string        `json:"kind"`
	URL        string        `json:"url,omitempty"`
	PreviewURL string        `json:"previewUrl,omitempty"`
	Format     string        `json:"format,omitempty"`
	Width      int           `json:"width,omitempty"`
	Height     int           `json:"height,omitempty"`
	Duration   time.Duration `json:"duration,omitempty"`
}

type Item struct {
	Ref         Ref       `json:"ref"`
	Title       string    `json:"title"`
	Summary     string    `json:"summary,omitempty"`
	Author      Author    `json:"author"`
	PublishedAt time.Time `json:"publishedAt,omitempty"`
	Stats       Stats     `json:"stats"`
	Media       []Media   `json:"media,omitempty"`
	Tags        []string  `json:"tags,omitempty"`
	Liked       bool      `json:"liked,omitempty"`
	Favorited   bool      `json:"favorited,omitempty"`
}

type Comment struct {
	Ref         Ref       `json:"ref"`
	Author      Author    `json:"author"`
	Body        string    `json:"body"`
	PublishedAt time.Time `json:"publishedAt,omitempty"`
	Likes       int64     `json:"likes,omitempty"`
	Media       []Media   `json:"media,omitempty"`
	Replies     []Comment `json:"replies,omitempty"`
}

type Detail struct {
	Item
	Body     string    `json:"body"`
	Comments []Comment `json:"comments,omitempty"`
}

type Page struct {
	Items      []Item   `json:"items"`
	NextCursor string   `json:"nextCursor,omitempty"`
	HasMore    bool     `json:"hasMore,omitempty"`
	Notices    []string `json:"notices,omitempty"`
}
