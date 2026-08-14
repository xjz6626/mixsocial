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
	Source   SourceID
	ID       string
	ParentID string
	Token    string
	URL      string
}

type Author struct {
	ID     string
	Name   string
	Avatar string
}

type Stats struct {
	Views     int64
	Likes     int64
	Comments  int64
	Favorites int64
	Shares    int64
}

type Media struct {
	Kind   string
	URL    string
	Width  int
	Height int
}

type Item struct {
	Ref         Ref
	Title       string
	Summary     string
	Author      Author
	PublishedAt time.Time
	Stats       Stats
	Media       []Media
	Tags        []string
	Liked       bool
	Favorited   bool
}

type Comment struct {
	Ref         Ref
	Author      Author
	Body        string
	PublishedAt time.Time
	Likes       int64
	Replies     []Comment
}

type Detail struct {
	Item
	Body     string
	Comments []Comment
}

type Page struct {
	Items      []Item
	NextCursor string
	HasMore    bool
	Notices    []string
}
