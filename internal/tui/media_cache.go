package tui

import (
	"container/list"
	"context"
	"crypto/sha256"
	"fmt"
	"image"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	mediaMemoryBytes = 192 << 20
	mediaMemoryItems = 256
	mediaDiskBytes   = 512 << 20
	mediaDiskVersion = "v1"
	mediaDecodeSize  = 2048
)

type nativePreviewSpec struct {
	config  terminalImageConfig
	columns int
	rows    int
}

type cachedMedia struct {
	url        string
	image      image.Image
	bytes      int64
	renders    map[nativePreviewSpec]nativeImagePreview
	renderMu   sync.Mutex
	lruElement *list.Element
}

type mediaLoadFlight struct {
	done  chan struct{}
	image image.Image
	err   error
}

type mediaCache struct {
	mu         sync.Mutex
	entries    map[string]*cachedMedia
	lru        list.List
	flights    map[string]*mediaLoadFlight
	bytes      int64
	directory  string
	diskMu     sync.Mutex
	diskWrites int
}

func newMediaCache() *mediaCache {
	cache := &mediaCache{
		entries: make(map[string]*cachedMedia),
		flights: make(map[string]*mediaLoadFlight),
	}
	if directory, err := os.UserCacheDir(); err == nil && directory != "" {
		cache.directory = filepath.Join(directory, "mixsocial", "media", mediaDiskVersion)
	}
	return cache
}

func (c *mediaCache) get(rawURL string) (image.Image, bool) {
	if c == nil {
		return nil, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[rawURL]
	if !ok || entry.image == nil {
		return nil, false
	}
	c.lru.MoveToFront(entry.lruElement)
	return entry.image, true
}

func (c *mediaCache) load(ctx context.Context, rawURL, referer string) (image.Image, error) {
	if imageValue, ok := c.get(rawURL); ok {
		return imageValue, nil
	}

	c.mu.Lock()
	if flight, ok := c.flights[rawURL]; ok {
		c.mu.Unlock()
		select {
		case <-flight.done:
			return flight.image, flight.err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	flight := &mediaLoadFlight{done: make(chan struct{})}
	c.flights[rawURL] = flight
	c.mu.Unlock()

	imageValue, err := c.loadUncached(ctx, rawURL, referer)
	if err == nil {
		// Keep enough source pixels for HiDPI native-image placements. The raw
		// response remains on disk, while the bounded decoded copy participates
		// in the memory LRU.
		imageValue = scaleTerminalImage(imageValue, mediaDecodeSize, mediaDecodeSize)
		c.put(rawURL, imageValue)
	}

	c.mu.Lock()
	flight.image, flight.err = imageValue, err
	delete(c.flights, rawURL)
	close(flight.done)
	c.mu.Unlock()
	return imageValue, err
}

func (c *mediaCache) loadUncached(ctx context.Context, rawURL, referer string) (image.Image, error) {
	if encoded, ok := c.readDisk(rawURL); ok {
		imageValue, err := decodeImageBytes(encoded)
		if err == nil {
			return imageValue, nil
		}
		_ = os.Remove(c.diskPath(rawURL))
	}
	encoded, err := fetchImageBytes(ctx, rawURL, referer)
	if err != nil {
		return nil, err
	}
	imageValue, err := decodeImageBytes(encoded)
	if err != nil {
		return nil, err
	}
	c.writeDisk(rawURL, encoded)
	return imageValue, nil
}

func (c *mediaCache) put(rawURL string, imageValue image.Image) {
	if c == nil || imageValue == nil {
		return
	}
	cost := imageMemoryCost(imageValue)
	c.mu.Lock()
	defer c.mu.Unlock()
	if existing, ok := c.entries[rawURL]; ok {
		c.bytes -= existing.bytes
		existing.image = imageValue
		existing.bytes = cost
		existing.renders = make(map[nativePreviewSpec]nativeImagePreview)
		c.bytes += cost
		c.lru.MoveToFront(existing.lruElement)
	} else {
		entry := &cachedMedia{url: rawURL, image: imageValue, bytes: cost, renders: make(map[nativePreviewSpec]nativeImagePreview)}
		entry.lruElement = c.lru.PushFront(entry)
		c.entries[rawURL] = entry
		c.bytes += cost
	}
	c.evictLocked()
}

func (c *mediaCache) native(rawURL string, spec nativePreviewSpec) (nativeImagePreview, bool) {
	if c == nil {
		return nativeImagePreview{}, false
	}
	c.mu.Lock()
	entry, ok := c.entries[rawURL]
	if ok {
		c.lru.MoveToFront(entry.lruElement)
	}
	c.mu.Unlock()
	if !ok {
		return nativeImagePreview{}, false
	}
	entry.renderMu.Lock()
	defer entry.renderMu.Unlock()
	preview, ok := entry.renders[spec]
	return preview, ok
}

func (c *mediaCache) renderNative(rawURL string, spec nativePreviewSpec) (nativeImagePreview, error) {
	c.mu.Lock()
	entry, ok := c.entries[rawURL]
	if ok {
		c.lru.MoveToFront(entry.lruElement)
	}
	c.mu.Unlock()
	if !ok || entry.image == nil {
		return nativeImagePreview{}, fmt.Errorf("media is not cached")
	}

	entry.renderMu.Lock()
	defer entry.renderMu.Unlock()
	if preview, exists := entry.renders[spec]; exists {
		return preview, nil
	}
	var preview nativeImagePreview
	var err error
	if spec.config.protocol == imageProtocolBlocks {
		columns, rows := terminalImageSize(entry.image.Bounds(), spec.columns, spec.rows)
		preview = nativeImagePreview{
			display: renderTerminalImage(entry.image, spec.columns, spec.rows),
			columns: columns,
			rows:    rows,
		}
	} else {
		preview, err = renderNativeImage(entry.image, spec.config, spec.columns, spec.rows, rawURL)
	}
	if err != nil {
		return nativeImagePreview{}, err
	}
	entry.renders[spec] = preview
	extra := int64(len(preview.transmit) + len(preview.display))

	c.mu.Lock()
	if current, exists := c.entries[rawURL]; exists && current == entry {
		entry.bytes += extra
		c.bytes += extra
		c.evictLocked()
	}
	c.mu.Unlock()
	return preview, nil
}

func (c *mediaCache) evictLocked() {
	for c.bytes > mediaMemoryBytes || len(c.entries) > mediaMemoryItems {
		oldest := c.lru.Back()
		if oldest == nil {
			return
		}
		entry := oldest.Value.(*cachedMedia)
		delete(c.entries, entry.url)
		c.lru.Remove(oldest)
		c.bytes -= entry.bytes
	}
}

func imageMemoryCost(imageValue image.Image) int64 {
	bounds := imageValue.Bounds()
	return int64(bounds.Dx()) * int64(bounds.Dy()) * 4
}

func (c *mediaCache) diskPath(rawURL string) string {
	if c == nil || c.directory == "" {
		return ""
	}
	digest := sha256.Sum256([]byte(rawURL))
	return filepath.Join(c.directory, fmt.Sprintf("%x.img", digest))
}

func (c *mediaCache) readDisk(rawURL string) ([]byte, bool) {
	path := c.diskPath(rawURL)
	if path == "" {
		return nil, false
	}
	encoded, err := os.ReadFile(path)
	if err != nil || len(encoded) == 0 || len(encoded) > maxMediaBytes {
		return nil, false
	}
	now := time.Now()
	_ = os.Chtimes(path, now, now)
	return encoded, true
}

func (c *mediaCache) writeDisk(rawURL string, encoded []byte) {
	path := c.diskPath(rawURL)
	if path == "" || len(encoded) == 0 {
		return
	}
	c.diskMu.Lock()
	defer c.diskMu.Unlock()
	if err := os.MkdirAll(c.directory, 0o700); err != nil {
		return
	}
	_ = os.Chmod(c.directory, 0o700)
	temporary, err := os.CreateTemp(c.directory, ".media-*")
	if err != nil {
		return
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	_ = temporary.Chmod(0o600)
	if _, err = temporary.Write(encoded); err == nil {
		err = temporary.Close()
	} else {
		_ = temporary.Close()
	}
	if err != nil || os.Rename(temporaryPath, path) != nil {
		return
	}
	c.diskWrites++
	if c.diskWrites%8 == 0 {
		pruneMediaDisk(c.directory)
	}
}

func pruneMediaDisk(directory string) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return
	}
	type diskEntry struct {
		path    string
		size    int64
		modTime time.Time
	}
	var files []diskEntry
	var total int64
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".img") {
			continue
		}
		info, infoErr := entry.Info()
		if infoErr != nil || !info.Mode().IsRegular() {
			continue
		}
		files = append(files, diskEntry{path: filepath.Join(directory, entry.Name()), size: info.Size(), modTime: info.ModTime()})
		total += info.Size()
	}
	if total <= mediaDiskBytes {
		return
	}
	sort.Slice(files, func(i, j int) bool { return files[i].modTime.Before(files[j].modTime) })
	for _, file := range files {
		if total <= mediaDiskBytes {
			break
		}
		if os.Remove(file.path) == nil {
			total -= file.size
		}
	}
}
