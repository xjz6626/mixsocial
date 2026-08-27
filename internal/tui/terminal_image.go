package tui

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"hash/fnv"
	"image"
	"image/png"
	"strings"

	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/ansi/iterm2"
	"github.com/charmbracelet/x/ansi/kitty"
	golangdraw "golang.org/x/image/draw"
)

type imageProtocol uint8

const (
	imageProtocolBlocks imageProtocol = iota
	imageProtocolKitty
	imageProtocolITerm2
	imageProtocolSixel
)

type imagePassthrough uint8

const (
	imagePassthroughNone imagePassthrough = iota
	imagePassthroughTmux
	imagePassthroughScreen
)

type terminalImageConfig struct {
	protocol    imageProtocol
	passthrough imagePassthrough
}

type nativeImagePreview struct {
	transmit string
	display  string
	columns  int
	rows     int
}

const (
	// Kitty and iTerm2 scale image pixels into a cell placement themselves.
	// Supplying more than the old 10x20 estimate preserves detail on HiDPI
	// displays without sending the full resolution of very large originals.
	nativePixelsPerColumn = 24
	nativePixelsPerRow    = 48
	sixelPixelsPerColumn  = 10
	sixelPixelsPerRow     = 20
)

func (p imageProtocol) String() string {
	switch p {
	case imageProtocolKitty:
		return "Kitty"
	case imageProtocolITerm2:
		return "iTerm2"
	case imageProtocolSixel:
		return "Sixel"
	default:
		return "ANSI"
	}
}

func (config terminalImageConfig) statusLabel() string {
	label := config.protocol.String()
	if config.protocol == imageProtocolBlocks {
		label += " 低清"
	}
	switch config.passthrough {
	case imagePassthroughTmux:
		label += "/tmux"
	case imagePassthroughScreen:
		label += "/screen"
	}
	return label
}

func detectTerminalImageConfig(getenv func(string) string) terminalImageConfig {
	config := terminalImageConfig{}
	override := strings.ToLower(strings.TrimSpace(getenv("MIXSOCIAL_IMAGE_PROTOCOL")))
	explicitNative := false
	switch override {
	case "kitty":
		config.protocol = imageProtocolKitty
		explicitNative = true
	case "iterm", "iterm2":
		config.protocol = imageProtocolITerm2
		explicitNative = true
	case "sixel":
		config.protocol = imageProtocolSixel
		explicitNative = true
	case "ansi", "blocks", "none", "off":
		config.protocol = imageProtocolBlocks
	default:
		term := strings.ToLower(getenv("TERM"))
		program := strings.ToLower(getenv("TERM_PROGRAM"))
		lcTerminal := strings.ToLower(getenv("LC_TERMINAL"))
		switch {
		case getenv("KITTY_WINDOW_ID") != "",
			strings.Contains(term, "kitty"),
			strings.Contains(program, "wezterm"),
			strings.Contains(program, "ghostty"),
			getenv("KONSOLE_VERSION") != "":
			config.protocol = imageProtocolKitty
		case strings.Contains(program, "iterm"), strings.Contains(lcTerminal, "iterm"):
			config.protocol = imageProtocolITerm2
		case strings.Contains(term, "sixel"),
			strings.Contains(term, "mlterm"),
			strings.Contains(term, "foot"),
			strings.Contains(program, "foot"),
			strings.Contains(program, "contour"):
			config.protocol = imageProtocolSixel
		}
	}

	switch {
	case getenv("TMUX") != "":
		config.passthrough = imagePassthroughTmux
	case getenv("STY") != "":
		config.passthrough = imagePassthroughScreen
	}
	// Multiplexers need an explicit passthrough setting that cannot be queried
	// portably. Keep auto mode readable and let configured users opt in.
	if config.passthrough != imagePassthroughNone && !explicitNative {
		config.protocol = imageProtocolBlocks
	}
	return config
}

func renderNativeImage(img image.Image, config terminalImageConfig, maxColumns, maxRows int, cacheKey string) (nativeImagePreview, error) {
	if img == nil || maxColumns < 1 || maxRows < 1 || config.protocol == imageProtocolBlocks {
		return nativeImagePreview{}, nil
	}
	columns, rows := terminalImageSize(img.Bounds(), maxColumns, maxRows)
	if columns < 1 || rows < 1 {
		return nativeImagePreview{}, nil
	}
	prepared := prepareNativeImage(img, config.protocol, columns, rows)

	switch config.protocol {
	case imageProtocolKitty:
		return renderKittyImage(prepared, config, columns, rows, stableImageID(cacheKey))
	case imageProtocolITerm2:
		return renderITerm2Image(prepared, config, columns, rows)
	case imageProtocolSixel:
		return renderSixelImage(prepared, config, columns, rows)
	default:
		return nativeImagePreview{}, nil
	}
}

func prepareNativeImage(img image.Image, protocol imageProtocol, columns, rows int) image.Image {
	pixelsPerColumn, pixelsPerRow := nativePixelsPerColumn, nativePixelsPerRow
	if protocol == imageProtocolSixel {
		// Sixel paints physical pixels instead of letting the terminal scale an
		// image into a cell placement, so use the conservative cell estimate.
		pixelsPerColumn, pixelsPerRow = sixelPixelsPerColumn, sixelPixelsPerRow
	}
	return scaleTerminalImage(img, columns*pixelsPerColumn, rows*pixelsPerRow)
}

func terminalImageSize(bounds image.Rectangle, maxColumns, maxRows int) (columns, rows int) {
	if bounds.Empty() || maxColumns < 1 || maxRows < 1 {
		return 0, 0
	}
	columns = maxColumns
	rows = max(1, (bounds.Dy()*columns+bounds.Dx()*2-1)/(bounds.Dx()*2))
	if rows > maxRows {
		rows = maxRows
		columns = max(1, min(columns, rows*2*bounds.Dx()/bounds.Dy()))
	}
	return columns, rows
}

func scaleTerminalImage(img image.Image, maxWidth, maxHeight int) image.Image {
	bounds := img.Bounds()
	if bounds.Empty() || maxWidth < 1 || maxHeight < 1 || (bounds.Dx() <= maxWidth && bounds.Dy() <= maxHeight) {
		return img
	}
	width := maxWidth
	height := max(1, bounds.Dy()*width/bounds.Dx())
	if height > maxHeight {
		height = maxHeight
		width = max(1, bounds.Dx()*height/bounds.Dy())
	}
	destination := image.NewNRGBA(image.Rect(0, 0, width, height))
	golangdraw.CatmullRom.Scale(destination, destination.Bounds(), img, bounds, golangdraw.Src, nil)
	return destination
}

func resizeTerminalImage(img image.Image, width, height int) image.Image {
	if img == nil || width < 1 || height < 1 {
		return img
	}
	bounds := img.Bounds()
	if bounds.Empty() || (bounds.Dx() == width && bounds.Dy() == height) {
		return img
	}
	destination := image.NewNRGBA(image.Rect(0, 0, width, height))
	golangdraw.CatmullRom.Scale(destination, destination.Bounds(), img, bounds, golangdraw.Src, nil)
	return destination
}

func renderKittyImage(img image.Image, config terminalImageConfig, columns, rows int, id uint32) (nativeImagePreview, error) {
	var transmit bytes.Buffer
	options := &kitty.Options{
		Action:           kitty.TransmitAndPut,
		Format:           kitty.PNG,
		ID:               int(id),
		PlacementID:      int(id),
		Columns:          columns,
		Rows:             rows,
		VirtualPlacement: true,
		DoNotMoveCursor:  true,
		Quite:            2,
		Chunk:            true,
		ChunkFormatter: func(chunk string) string {
			return imageProtocolPassthrough(config, chunk)
		},
	}
	if err := kitty.EncodeGraphics(&transmit, img, options); err != nil {
		return nativeImagePreview{}, err
	}

	red, green, blue := imageIDColor(id)
	var display strings.Builder
	for row := 0; row < rows; row++ {
		fmt.Fprintf(&display, "\x1b[38;2;%d;%d;%dm\x1b[58;2;%d;%d;%dm", red, green, blue, red, green, blue)
		for column := 0; column < columns; column++ {
			display.WriteRune(kitty.Placeholder)
			display.WriteRune(kitty.Diacritic(row))
			display.WriteRune(kitty.Diacritic(column))
		}
		display.WriteString("\x1b[0m")
		if row+1 < rows {
			display.WriteByte('\n')
		}
	}
	return nativeImagePreview{transmit: transmit.String(), display: display.String(), columns: columns, rows: rows}, nil
}

func renderITerm2Image(img image.Image, config terminalImageConfig, columns, rows int) (nativeImagePreview, error) {
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		return nativeImagePreview{}, err
	}
	content := make([]byte, base64.StdEncoding.EncodedLen(encoded.Len()))
	base64.StdEncoding.Encode(content, encoded.Bytes())
	sequence := ansi.ITerm2(iterm2.File{
		Size:            int64(encoded.Len()),
		Width:           iterm2.Cells(columns),
		Height:          iterm2.Cells(rows),
		Inline:          true,
		DoNotMoveCursor: true,
		Content:         content,
	})
	sequence = imageProtocolPassthrough(config, ansi.SaveCursor+sequence+ansi.RestoreCursor)
	return nativeImagePreview{display: reserveImageRows(sequence, columns, rows), columns: columns, rows: rows}, nil
}

func renderSixelImage(img image.Image, config terminalImageConfig, columns, rows int) (nativeImagePreview, error) {
	payload := encodeSixelPayload(img)
	sequence := ansi.SixelGraphics(0, 1, 0, payload)
	sequence = imageProtocolPassthrough(config, ansi.SaveCursor+sequence+ansi.RestoreCursor)
	return nativeImagePreview{display: reserveImageRows(sequence, columns, rows), columns: columns, rows: rows}, nil
}

// encodeSixelPayload uses a fixed 6×6×6 RGB palette. Keeping the encoder
// local avoids an optional dependency while still retaining far more detail
// than the ANSI half-block fallback.
func encodeSixelPayload(img image.Image) []byte {
	bounds := img.Bounds()
	if bounds.Empty() {
		return nil
	}
	width, height := bounds.Dx(), bounds.Dy()
	pixels := make([]uint8, width*height)
	used := make([]bool, 216)
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			r, g, b := terminalRGB(img.At(bounds.Min.X+x, bounds.Min.Y+y))
			index := sixelPaletteIndex(r, g, b)
			pixels[y*width+x] = index
			used[index] = true
		}
	}

	var output bytes.Buffer
	fmt.Fprintf(&output, "\"1;1;%d;%d", width, height)
	for index, present := range used {
		if !present {
			continue
		}
		red := index / 36
		green := (index / 6) % 6
		blue := index % 6
		fmt.Fprintf(&output, "#%d;2;%d;%d;%d", index, red*20, green*20, blue*20)
	}

	bands := (height + 5) / 6
	column := make([]byte, width)
	for band := 0; band < bands; band++ {
		var bandColors [216]bool
		for bit := 0; bit < 6; bit++ {
			y := band*6 + bit
			if y >= height {
				break
			}
			for x := 0; x < width; x++ {
				bandColors[pixels[y*width+x]] = true
			}
		}
		firstColor := true
		for index, present := range bandColors {
			if !present {
				continue
			}
			hasColor := false
			for x := 0; x < width; x++ {
				var bits byte
				for bit := 0; bit < 6; bit++ {
					y := band*6 + bit
					if y < height && int(pixels[y*width+x]) == index {
						bits |= 1 << bit
						hasColor = true
					}
				}
				column[x] = '?' + bits
			}
			if !hasColor {
				continue
			}
			if !firstColor {
				output.WriteByte('$')
			}
			firstColor = false
			fmt.Fprintf(&output, "#%d", index)
			writeSixelRun(&output, column)
		}
		if band+1 < bands {
			output.WriteByte('-')
		}
	}
	return output.Bytes()
}

func sixelPaletteIndex(red, green, blue uint8) uint8 {
	r := (int(red)*5 + 127) / 255
	g := (int(green)*5 + 127) / 255
	b := (int(blue)*5 + 127) / 255
	return uint8(r*36 + g*6 + b)
}

func writeSixelRun(output *bytes.Buffer, values []byte) {
	for start := 0; start < len(values); {
		end := start + 1
		for end < len(values) && values[end] == values[start] {
			end++
		}
		count := end - start
		if count >= 4 {
			fmt.Fprintf(output, "!%d%c", count, values[start])
		} else {
			for range count {
				output.WriteByte(values[start])
			}
		}
		start = end
	}
}

func reserveImageRows(sequence string, columns, rows int) string {
	var output strings.Builder
	for row := 0; row < rows; row++ {
		if row == 0 {
			output.WriteString(sequence)
		}
		// Literal cells let Lip Gloss and Bubble Tea account for the image's
		// width while the protocol sequence paints into the same cell region.
		output.WriteString(strings.Repeat(" ", columns))
		if row+1 < rows {
			output.WriteByte('\n')
		}
	}
	return output.String()
}

func imageProtocolPassthrough(config terminalImageConfig, sequence string) string {
	switch config.passthrough {
	case imagePassthroughTmux:
		return ansi.TmuxPassthrough(sequence)
	case imagePassthroughScreen:
		return ansi.ScreenPassthrough(sequence, 700)
	default:
		return sequence
	}
}

func stableImageID(value string) uint32 {
	digest := fnv.New32a()
	_, _ = digest.Write([]byte(value))
	// Unicode placeholders carry 24 bits of the image and placement IDs.
	id := digest.Sum32() & 0x00ffffff
	if id == 0 {
		return 1
	}
	return id
}

func imageIDColor(id uint32) (red, green, blue uint8) {
	return uint8(id >> 16), uint8(id >> 8), uint8(id)
}
