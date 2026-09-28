// Portions of this file are adapted and modified from github.com/JimChengLin/zhihu-tui
// under the Apache License 2.0. See NOTICE and THIRD_PARTY.md.
package zhihu

import (
	"encoding/json"
	"html"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
)

var (
	blockTagPattern   = regexp.MustCompile(`(?i)<(?:br\s*/?|/?(?:p|div|li|blockquote|h[1-6]|pre))[^>]*>`)
	htmlTagPattern    = regexp.MustCompile(`(?s)<[^>]+>`)
	repeatedNewlines  = regexp.MustCompile(`\n[\t ]*\n(?:[\t ]*\n)+`)
	imageTagPattern   = regexp.MustCompile(`(?is)<img\b[^>]*>`)
	attributePattern  = regexp.MustCompile(`(?is)([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))`)
	unsafeHTMLPattern = regexp.MustCompile(`(?is)<(?:script|style)\b[^>]*>.*?</(?:script|style)\s*>`)
)

func pageFromValue(value any, cursor string, offset int) domain.Page {
	if object, ok := value.(map[string]any); ok {
		return pageFromResponse(object, cursor, offset)
	}
	items := itemsFromSlice(sliceValue(value))
	return domain.Page{Items: items}
}

func pageFromResponse(response map[string]any, cursor string, offset int) domain.Page {
	data := responseData(response)
	items := itemsFromSlice(data)
	page := domain.Page{Items: items}
	paging := mapValue(response["paging"])
	if len(paging) == 0 {
		return page
	}
	next := strings.TrimSpace(stringValue(paging["next"]))
	end := boolValue(paging["is_end"])
	if next != "" && next != cursor && !end {
		page.NextCursor = next
		page.HasMore = true
		return page
	}
	if !end && len(items) > 0 {
		page.NextCursor = strconv.Itoa(offset + len(data))
		page.HasMore = true
	}
	return page
}

func responseData(response map[string]any) []any {
	data := sliceValue(response["data"])
	if len(data) == 0 {
		data = sliceValue(response["items"])
	}
	return data
}

func itemsFromSlice(data []any) []domain.Item {
	items := make([]domain.Item, 0, len(data))
	for _, rawValue := range data {
		raw := mapValue(rawValue)
		if item, ok := itemFromActivity(raw); ok {
			items = append(items, item)
		}
		for _, grouped := range sliceValue(raw["list"]) {
			if item, ok := itemFromActivity(mapValue(grouped)); ok {
				items = append(items, item)
			}
		}
	}
	return items
}

func itemFromActivity(raw map[string]any) (domain.Item, bool) {
	target := mapValue(raw["target"])
	if len(target) == 0 {
		target = mapValue(raw["object"])
	}
	if nested := mapValue(target["object"]); len(nested) > 0 {
		target = nested
	}
	if len(target) == 0 {
		if question := mapValue(raw["question"]); len(question) > 0 {
			target = cloneMap(question)
			reaction := mapValue(raw["reaction"])
			target["view_count"] = firstValue(reaction["pv"], reaction["new_pv"])
			target["voteup_count"] = firstValue(reaction["upvote_num"], reaction["new_upvote_num"])
			target["comment_count"] = firstValue(reaction["answer_num"], reaction["new_answer_num"])
		}
	}
	if len(target) == 0 {
		target = raw
	}
	item, ok := itemFromTarget(target)
	if !ok {
		return domain.Item{}, false
	}
	if item.Summary == "" {
		highlight := mapValue(raw["highlight"])
		item.Summary = textValue(firstValue(highlight["description"], highlight["content"]))
	}
	if item.PublishedAt.IsZero() {
		item.PublishedAt = unixTime(firstValue(raw["created_time"], raw["created"]))
	}
	return item, true
}

func itemFromTarget(target map[string]any) (domain.Item, bool) {
	kind := normalizedKind(stringValue(target["type"]))
	if kind == "" {
		kind = kindFromURL(stringValue(target["url"]))
	}
	if kind == "" {
		return domain.Item{}, false
	}
	id := strings.TrimSpace(firstString(target["id"], target["url_token"]))
	if id == "" {
		return domain.Item{}, false
	}
	question := mapValue(target["question"])
	authorData := mapValue(target["author"])
	if len(authorData) == 0 {
		authorData = mapValue(target["creator"])
	}
	author := authorFromMap(authorData)
	title := textValue(firstValue(target["title"], question["title"], target["name"]))
	summary := contentText(firstValue(target["excerpt_new"], target["excerpt"], target["description"], target["detail"], target["content"]))
	if title == "" {
		title = firstLine(summary)
	}
	if title == "" {
		title = contentTypeLabel(kind)
	}
	parentID := ""
	if kind == "answer" {
		parentID = firstString(question["id"], target["question_id"])
	}
	item := domain.Item{
		Ref: domain.Ref{
			Source: domain.SourceZhihu, ID: id, ParentID: parentID, Token: kind,
			URL: contentURL(kind, id, parentID),
		},
		Title: title, Summary: summary, Author: author,
		PublishedAt: unixTime(firstValue(target["created_time"], target["created"], target["published_time"])),
		Stats: domain.Stats{
			Views:     int64Value(firstValue(target["view_count"], target["visit_count"], target["read_count"])),
			Likes:     int64Value(firstValue(target["voteup_count"], target["reaction_count"], target["like_count"], target["liked_count"])),
			Comments:  int64Value(firstValue(target["comment_count"], target["comments_count"])),
			Favorites: int64Value(firstValue(target["favlists_count"], target["favorite_count"], target["collection_count"])),
			Shares:    int64Value(firstValue(target["share_count"], target["shares_count"])),
		},
		Media:     mediaFromTarget(target),
		Liked:     contentLiked(target),
		Favorited: boolValue(firstValue(target["is_collected"], target["is_favorited"])),
	}
	for _, topicValue := range sliceValue(firstValue(target["topics"], question["topics"])) {
		if name := textValue(mapValue(topicValue)["name"]); name != "" {
			item.Tags = append(item.Tags, name)
		}
	}
	return item, true
}

func detailFromTarget(target map[string]any) domain.Detail {
	item, ok := itemFromTarget(target)
	if !ok {
		item = domain.Item{
			Ref:   domain.Ref{Source: domain.SourceZhihu, ID: firstString(target["id"], target["url_token"]), Token: normalizedKind(stringValue(target["type"]))},
			Title: textValue(target["title"]), Author: authorFromMap(mapValue(target["author"])),
		}
	}
	body := contentText(firstValue(target["content"], target["detail"], target["excerpt_new"], target["excerpt"], target["description"]))
	media := append([]domain.Media(nil), item.Media...)
	if item.Ref.Token == "question" {
		for _, rawAnswer := range sliceValue(target["top_answers"]) {
			answer := mapValue(rawAnswer)
			answerBody := contentText(firstValue(answer["content"], answer["excerpt_new"], answer["excerpt"]))
			if answerBody == "" {
				continue
			}
			author := authorFromMap(mapValue(answer["author"]))
			body += "\n\n热门回答 · " + firstNonEmpty(author.Name, "匿名用户") + "\n" + answerBody
			media = appendUniqueMedia(media, mediaFromTarget(answer)...)
		}
	}
	item.Media = media
	return domain.Detail{Item: item, Body: strings.TrimSpace(body)}
}

func authorFromMap(raw map[string]any) domain.Author {
	member := mapValue(raw["member"])
	if len(member) > 0 {
		raw = member
	}
	id := firstString(raw["id"], raw["url_token"])
	token := strings.TrimSpace(stringValue(raw["url_token"]))
	profileURL := ""
	if token != "" {
		profileURL = "https://www.zhihu.com/people/" + url.PathEscape(token)
	}
	return domain.Author{
		Ref: domain.ProfileRef{Source: domain.SourceZhihu, ID: id, Token: token, URL: profileURL},
		ID:  id, Name: textValue(raw["name"]),
		Avatar:    firstString(raw["avatar_url"], raw["avatar_url_template"], raw["avatar"]),
		Following: boolValue(raw["is_following"]),
	}
}

func commentPageFromResponse(response map[string]any, kind, contentID, cursor string) domain.CommentPage {
	page := domain.CommentPage{}
	for _, raw := range sliceValue(response["data"]) {
		comment := commentFromMap(mapValue(raw), kind, contentID, "")
		if comment.Ref.ID != "" && comment.Body != "" {
			page.Comments = append(page.Comments, comment)
		}
	}
	paging := mapValue(response["paging"])
	nextURL := strings.TrimSpace(stringValue(paging["next"]))
	if parsed, err := url.Parse(nextURL); err == nil {
		page.NextCursor = parsed.Query().Get("offset")
	}
	page.HasMore = !boolValue(paging["is_end"]) && page.NextCursor != "" && page.NextCursor != cursor
	return page
}

func commentFromMap(raw map[string]any, kind, contentID, parentCommentID string) domain.Comment {
	authorData := mapValue(raw["author"])
	if member := mapValue(authorData["member"]); len(member) > 0 {
		authorData = member
	}
	commentID := stringValue(raw["id"])
	comment := domain.Comment{
		Ref:         domain.Ref{Source: domain.SourceZhihu, ID: commentID, ParentID: contentID, Token: kind},
		Author:      authorFromMap(authorData),
		Body:        contentText(raw["content"]),
		PublishedAt: unixTime(firstValue(raw["created_time"], raw["created"])),
		Likes:       int64Value(firstValue(raw["vote_count"], raw["like_count"])),
		ReplyCount:  int64Value(raw["child_comment_count"]),
		Media:       mediaFromContent(raw["content"]),
	}
	if parentCommentID != "" {
		comment.Ref.ParentID = parentCommentID
	}
	for _, rawChild := range sliceValue(raw["child_comments"]) {
		child := commentFromMap(mapValue(rawChild), kind, contentID, commentID)
		if child.Ref.ID != "" && child.Body != "" {
			comment.Replies = append(comment.Replies, child)
		}
	}
	return comment
}

func mediaFromTarget(target map[string]any) []domain.Media {
	media := mediaFromContent(firstValue(target["content"], target["detail"], target["excerpt_new"], target["excerpt"]))
	for _, value := range []any{target["images"], target["image_list"], target["thumbnail"], target["image_url"], target["cover"]} {
		media = appendUniqueMedia(media, mediaFromStructured(value, "image")...)
	}
	media = appendUniqueMedia(media, mediaFromStructured(target["video"], "video")...)
	return media
}

func mediaFromContent(value any) []domain.Media {
	var media []domain.Media
	switch typed := value.(type) {
	case string:
		for _, tag := range imageTagPattern.FindAllString(typed, -1) {
			attributes := htmlAttributes(tag)
			imageURL := firstNonEmpty(attributes["data-original"], attributes["data-actualsrc"], attributes["data-default-watermark-src"], attributes["src"])
			if imageURL == "" || strings.HasPrefix(imageURL, "data:") {
				continue
			}
			media = appendUniqueMedia(media, domain.Media{
				Kind: "image", URL: normalizeMediaURL(imageURL), PreviewURL: normalizeMediaURL(attributes["data-thumbnail"]),
				Width:  int(int64Value(firstNonEmpty(attributes["data-rawwidth"], attributes["width"]))),
				Height: int(int64Value(firstNonEmpty(attributes["data-rawheight"], attributes["height"]))),
			})
		}
	default:
		for _, rawNode := range sliceValue(typed) {
			node := mapValue(rawNode)
			nodeKind := strings.ToLower(stringValue(node["type"]))
			if nodeKind == "image" || nodeKind == "video" {
				media = appendUniqueMedia(media, mediaFromStructured(node, nodeKind)...)
			}
			media = appendUniqueMedia(media, mediaFromContent(node["content"])...)
		}
	}
	return media
}

func mediaFromStructured(value any, kind string) []domain.Media {
	if value == nil {
		return nil
	}
	if text, ok := value.(string); ok {
		if strings.HasPrefix(text, "http://") || strings.HasPrefix(text, "https://") || strings.HasPrefix(text, "//") {
			return []domain.Media{{Kind: kind, URL: normalizeMediaURL(text)}}
		}
		return nil
	}
	if list, ok := value.([]any); ok {
		var result []domain.Media
		for _, child := range list {
			result = appendUniqueMedia(result, mediaFromStructured(child, kind)...)
		}
		return result
	}
	raw := mapValue(value)
	if len(raw) == 0 {
		return nil
	}
	if nestedKind := strings.ToLower(stringValue(raw["type"])); nestedKind == "image" || nestedKind == "video" {
		kind = nestedKind
	}
	mediaURL := firstString(raw["original_url"], raw["originalUrl"], raw["play_url"], raw["playlist"], raw["url"], raw["src"], raw["image_url"], raw["url_normal"])
	preview := firstString(raw["thumbnail"], raw["thumbnail_url"], raw["cover"], raw["preview_url"])
	var result []domain.Media
	if mediaURL != "" {
		result = append(result, domain.Media{
			Kind: kind, URL: normalizeMediaURL(mediaURL), PreviewURL: normalizeMediaURL(preview),
			Width:    int(int64Value(firstValue(raw["width"], raw["original_width"]))),
			Height:   int(int64Value(firstValue(raw["height"], raw["original_height"]))),
			Duration: time.Duration(int64Value(raw["duration"])) * time.Second,
		})
	}
	for _, key := range []string{"image", "images", "video", "playlist", "cover", "thumbnail"} {
		childKind := kind
		if strings.Contains(key, "image") || key == "cover" || key == "thumbnail" {
			childKind = "image"
		}
		result = appendUniqueMedia(result, mediaFromStructured(raw[key], childKind)...)
	}
	return result
}

func appendUniqueMedia(existing []domain.Media, additions ...domain.Media) []domain.Media {
	seen := make(map[string]bool, len(existing)+len(additions))
	for _, media := range existing {
		seen[media.Kind+"\x00"+media.URL] = true
	}
	for _, media := range additions {
		if media.URL == "" || seen[media.Kind+"\x00"+media.URL] {
			continue
		}
		seen[media.Kind+"\x00"+media.URL] = true
		existing = append(existing, media)
	}
	return existing
}

func htmlAttributes(tag string) map[string]string {
	attributes := make(map[string]string)
	for _, match := range attributePattern.FindAllStringSubmatch(tag, -1) {
		value := firstNonEmpty(match[2], match[3], match[4])
		attributes[strings.ToLower(match[1])] = html.UnescapeString(value)
	}
	return attributes
}

func contentText(value any) string {
	if value == nil {
		return ""
	}
	if text, ok := value.(string); ok {
		return cleanHTML(text)
	}
	var parts []string
	for _, rawNode := range sliceValue(value) {
		node := mapValue(rawNode)
		if strings.EqualFold(stringValue(node["type"]), "image") {
			continue
		}
		if text := contentText(firstValue(node["content"], node["text"], node["title"])); text != "" {
			parts = append(parts, text)
		}
	}
	return strings.TrimSpace(strings.Join(parts, "\n\n"))
}

func cleanHTML(value string) string {
	value = unsafeHTMLPattern.ReplaceAllString(value, "")
	value = imageTagPattern.ReplaceAllString(value, "")
	value = blockTagPattern.ReplaceAllString(value, "\n")
	value = htmlTagPattern.ReplaceAllString(value, "")
	value = html.UnescapeString(value)
	value = strings.ReplaceAll(value, "\r\n", "\n")
	value = repeatedNewlines.ReplaceAllString(value, "\n\n")
	return strings.TrimSpace(value)
}

func contentLiked(target map[string]any) bool {
	if boolValue(firstValue(target["is_liked"], target["liked"], target["is_voted"])) {
		return true
	}
	relationship := mapValue(target["relationship"])
	return int64Value(firstValue(target["voting"], relationship["voting"])) > 0
}

func contentURL(kind, id, parentID string) string {
	switch kind {
	case "answer":
		if parentID != "" {
			return "https://www.zhihu.com/question/" + url.PathEscape(parentID) + "/answer/" + url.PathEscape(id)
		}
		return "https://www.zhihu.com/answer/" + url.PathEscape(id)
	case "article":
		return "https://zhuanlan.zhihu.com/p/" + url.PathEscape(id)
	case "pin":
		return "https://www.zhihu.com/pin/" + url.PathEscape(id)
	case "question":
		return "https://www.zhihu.com/question/" + url.PathEscape(id)
	default:
		return ""
	}
}

func normalizedKind(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.TrimSuffix(value, "s")
	switch value {
	case "answer", "article", "pin", "question":
		return value
	default:
		return ""
	}
}

func kindFromURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	path := parsed.Path
	switch {
	case strings.Contains(path, "/answer/"):
		return "answer"
	case strings.Contains(path, "/question/"):
		return "question"
	case strings.Contains(path, "/pin/"):
		return "pin"
	case strings.Contains(path, "/p/"):
		return "article"
	default:
		return ""
	}
}

func contentTypeLabel(kind string) string {
	switch kind {
	case "answer":
		return "知乎回答"
	case "article":
		return "知乎文章"
	case "pin":
		return "知乎想法"
	case "question":
		return "知乎问题"
	default:
		return "知乎内容"
	}
}

func mapValue(value any) map[string]any {
	result, _ := value.(map[string]any)
	return result
}

func sliceValue(value any) []any {
	result, _ := value.([]any)
	return result
}

func stringValue(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case json.Number:
		return typed.String()
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case int:
		return strconv.Itoa(typed)
	case int64:
		return strconv.FormatInt(typed, 10)
	default:
		return ""
	}
}

func firstString(values ...any) string {
	for _, value := range values {
		if result := strings.TrimSpace(stringValue(value)); result != "" {
			return result
		}
	}
	return ""
}

func firstValue(values ...any) any {
	for _, value := range values {
		if value == nil {
			continue
		}
		if text, ok := value.(string); ok && strings.TrimSpace(text) == "" {
			continue
		}
		return value
	}
	return nil
}

func textValue(value any) string { return cleanHTML(stringValue(value)) }

func int64Value(value any) int64 {
	switch typed := value.(type) {
	case json.Number:
		result, _ := typed.Int64()
		return result
	case float64:
		return int64(typed)
	case float32:
		return int64(typed)
	case int:
		return int64(typed)
	case int64:
		return typed
	case string:
		result, _ := strconv.ParseInt(strings.TrimSpace(typed), 10, 64)
		return result
	default:
		return 0
	}
}

func boolValue(value any) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case string:
		result, _ := strconv.ParseBool(typed)
		return result || typed == "1"
	default:
		return int64Value(value) != 0
	}
}

func unixTime(value any) time.Time {
	seconds := int64Value(value)
	if seconds <= 0 {
		return time.Time{}
	}
	return time.Unix(seconds, 0)
}

func normalizeMediaURL(value string) string {
	value = html.UnescapeString(strings.TrimSpace(value))
	if strings.HasPrefix(value, "//") {
		return "https:" + value
	}
	if strings.HasPrefix(value, "http://") {
		return "https://" + strings.TrimPrefix(value, "http://")
	}
	return value
}

func firstLine(value string) string {
	if index := strings.IndexByte(value, '\n'); index >= 0 {
		return strings.TrimSpace(value[:index])
	}
	return strings.TrimSpace(value)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
