package tieba

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"strconv"
	"time"

	"github.com/xjz6626/mixsocial/internal/domain"
)

const (
	personalizedVersion   = "12.52.1.0"
	personalizedPageSize  = 11
	personalizedUserAgent = "Mozilla/5.0 (Linux; Android 13; mixsocial Build/TQ3A.230805.001; wv) " +
		"AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/109.0.5414.86 Mobile Safari/537.36 " +
		"tieba/" + personalizedVersion
)

// personalized reads Tieba's official recommendation feed. The request and
// response field numbers match the mobile protobuf route also used by
// TiebaLite 4.0-dev; the wire encoding here is implemented independently.
func (p *Provider) personalized(ctx context.Context, cursor string) (domain.Page, error) {
	pageNumber := positiveInt(cursor, 1)
	session, err := p.sessionSnapshot()
	if err != nil {
		return domain.Page{}, err
	}
	request := encodePersonalizedRequest(session, p.clientID, pageNumber, time.Now())
	response, err := p.postProtoWithSession(ctx, p.recommendURL, request, &session)
	if err != nil {
		return domain.Page{}, err
	}
	return decodePersonalizedResponse(response, pageNumber)
}

func encodePersonalizedRequest(session sessionData, clientID string, pageNumber int, now time.Time) []byte {
	loadType := 1
	if pageNumber > 1 {
		loadType = 2
	}

	var appPosition []byte
	appPosition = appendString(appPosition, 1, "02:00:00:00:00:00")
	appPosition = appendUint(appPosition, 2, 1)
	appPosition = appendString(appPosition, 3, "BD09LL")

	var data []byte
	data = appendBytes(data, 1, encodePersonalizedCommon(session, clientID, now))
	data = appendUint(data, 4, uint64(loadType))
	data = appendUint(data, 5, personalizedPageSize)
	data = appendUint(data, 6, uint64(pageNumber))
	data = appendUint(data, 8, 1080)
	data = appendUint(data, 9, 1920)
	data = appendDouble(data, 10, 3)
	data = appendUint(data, 11, 1)
	data = appendUint(data, 23, 1)
	data = appendBytes(data, 36, appPosition)
	return appendBytes(nil, 1, data)
}

func encodePersonalizedCommon(session sessionData, clientID string, now time.Time) []byte {
	timestamp := uint64(now.UnixMilli())
	var common []byte
	common = appendUint(common, 1, 2)
	common = appendString(common, 2, personalizedVersion)
	common = appendString(common, 3, clientID)
	common = appendString(common, 6, "1020031h")
	common = appendString(common, 7, clientID)
	common = appendUint(common, 8, timestamp)
	common = appendString(common, 9, "mixsocial")
	common = appendString(common, 10, session.BDUSS)
	common = appendUint(common, 12, 1)
	common = appendString(common, 24, "1.0.3")
	common = appendString(common, 25, "13")
	common = appendString(common, 26, "generic")
	common = appendString(common, 28, "3.0.0")
	common = appendString(common, 30, session.STOKEN)
	common = appendString(common, 32, clientID)
	common = appendUint(common, 37, 1080)
	common = appendUint(common, 38, 1920)
	common = appendDouble(common, 39, 3)
	common = appendString(common, 42, "2.34.0")
	common = appendString(common, 43, "3340042")
	common = appendString(common, 44, "1038000")
	common = appendUint(common, 49, timestamp)
	common = appendUint(common, 50, timestamp)
	common = appendUint(common, 51, timestamp)
	common = appendString(common, 53, now.Format("20060102"))
	common = appendUint(common, 55, 1)
	common = appendUint(common, 57, 1)
	common = appendString(common, 62, personalizedUserAgent)
	common = appendUint(common, 63, 1)
	return common
}

func appendDouble(dst []byte, number int, value float64) []byte {
	dst = appendTag(dst, number, 1)
	return binary.LittleEndian.AppendUint64(dst, math.Float64bits(value))
}

func decodePersonalizedResponse(body []byte, pageNumber int) (domain.Page, error) {
	root, err := parseFields(body)
	if err != nil {
		return domain.Page{}, fmt.Errorf("decode Tieba recommendation response: %w", err)
	}
	if err := responseError(root); err != nil {
		return domain.Page{}, err
	}
	data, err := parseFields(firstBytes(root, 2))
	if err != nil {
		return domain.Page{}, fmt.Errorf("decode Tieba recommendation data: %w", err)
	}

	threads := allBytes(data, 2)
	page := domain.Page{HasMore: len(threads) > 0}
	if page.HasMore {
		page.NextCursor = strconv.Itoa(pageNumber + 1)
	}
	for _, encoded := range threads {
		fields, parseErr := parseFields(encoded)
		if parseErr != nil || len(firstBytes(fields, 113)) > 0 {
			// TiebaLite excludes live-room cards from its recommendation feed.
			continue
		}
		item, parseErr := decodeThread(encoded, "")
		if parseErr == nil && item.Ref.ID != "" && item.Ref.ID != "0" &&
			(item.Title != "" || item.Summary != "" || len(item.Media) > 0) {
			page.Items = append(page.Items, item)
		}
	}
	return page, nil
}
