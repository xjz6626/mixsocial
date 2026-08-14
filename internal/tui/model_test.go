package tui

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	qrcode "github.com/skip2/go-qrcode"

	"github.com/xjz6626/mixsocial/internal/domain"
	"github.com/xjz6626/mixsocial/internal/source"
	"github.com/xjz6626/mixsocial/internal/source/demo"
)

type authDemo struct {
	*demo.Provider
	image []byte
}

type credentialDemo struct {
	*demo.Provider
	credential string
}

func (a *credentialDemo) ID() domain.SourceID { return domain.SourceTieba }
func (a *credentialDemo) Name() string        { return "test tieba" }
func (a *credentialDemo) LoginStatus(context.Context) (source.LoginStatus, error) {
	return source.LoginStatus{LoggedIn: a.credential != "", Username: "bob"}, nil
}
func (a *credentialDemo) LoginWithCredential(_ context.Context, credential string) (source.LoginStatus, error) {
	a.credential = credential
	return source.LoginStatus{LoggedIn: true, Username: "bob", UserID: "42"}, nil
}

func (a authDemo) ID() domain.SourceID { return domain.SourceXHS }
func (a authDemo) Name() string        { return "test xhs" }
func (a authDemo) LoginQRCode(context.Context) (source.LoginChallenge, error) {
	return source.LoginChallenge{Image: a.image, Timeout: time.Minute}, nil
}
func (a authDemo) LoginStatus(context.Context) (source.LoginStatus, error) {
	return source.LoginStatus{LoggedIn: true, Username: "alice"}, nil
}

func TestModelLoadsAndOpensDemo(t *testing.T) {
	model := New(source.NewMixed(demo.New()), time.Second)
	message := model.Init()().(pageMsg)
	updated, _ := model.Update(message)
	model = updated.(Model)
	if len(model.items) != 2 {
		t.Fatalf("items = %d", len(model.items))
	}
	updated, command := model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(Model)
	if command == nil {
		t.Fatal("enter did not request detail")
	}
	updated, _ = model.Update(command())
	model = updated.(Model)
	if model.mode != detailView || model.detail == nil {
		t.Fatal("detail was not opened")
	}
}

func TestSearchInput(t *testing.T) {
	model := New(source.NewMixed(demo.New()), time.Second)
	updated, _ := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'/'}})
	model = updated.(Model)
	if model.inputMode != inputSearch {
		t.Fatal("search input did not focus")
	}
}

func TestRenderQRCode(t *testing.T) {
	img := image.NewGray(image.Rect(0, 0, 29, 29))
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		t.Fatal(err)
	}
	rendered, err := renderQRCode(encoded.Bytes(), 29)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rendered, "\x1b[40m") {
		t.Fatalf("QR output did not contain dark cells: %q", rendered)
	}
}

func TestRenderQRCodeRegeneratesScannableGrid(t *testing.T) {
	encoded, err := qrcode.Encode("https://example.test/login?token=terminal-qr", qrcode.Medium, 128)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := renderQRCode(encoded, 75)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(rendered, "\n")
	if len(lines) < 13 {
		t.Fatalf("regenerated QR is too short: %d lines", len(lines))
	}
	if !strings.HasPrefix(lines[0], "\x1b[47m ") || strings.Contains(lines[0], "\x1b[40m") {
		t.Fatalf("regenerated QR is missing its white quiet zone: %q", lines[0])
	}
}

func TestRenderQRCodeRecoversImageWithoutQuietZone(t *testing.T) {
	encoded, err := qrcode.Encode("https://example.test/qr/no-margin", qrcode.Low, 128)
	if err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(bytes.NewReader(encoded))
	if err != nil {
		t.Fatal(err)
	}
	bounds := img.Bounds()
	dark := image.Rect(bounds.Max.X, bounds.Max.Y, bounds.Min.X, bounds.Min.Y)
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			r, g, b, _ := img.At(x, y).RGBA()
			if r+g+b < 3*0x8000 {
				if dark.Empty() {
					dark = image.Rect(x, y, x+1, y+1)
				} else {
					dark = dark.Union(image.Rect(x, y, x+1, y+1))
				}
			}
		}
	}
	if dark.Empty() {
		t.Fatal("test QR contains no dark modules")
	}
	var cropped bytes.Buffer
	if err := png.Encode(&cropped, img.(interface {
		SubImage(image.Rectangle) image.Image
	}).SubImage(dark)); err != nil {
		t.Fatal(err)
	}
	rendered, err := renderQRCode(cropped.Bytes(), 75)
	if err != nil {
		t.Fatal(err)
	}
	first := strings.Split(rendered, "\n")[0]
	if !strings.HasPrefix(first, "\x1b[47m ") || strings.Contains(first, "\x1b[40m") {
		t.Fatalf("recovered QR is missing its quiet zone: %q", first)
	}
}

func TestRenderQRCodeUsesCompactBrailleWhenTerminalIsShort(t *testing.T) {
	encoded, err := qrcode.Encode(strings.Repeat("compact-terminal-login-token-", 8), qrcode.Low, 256)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := renderQRCode(encoded, 75, 18)
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Count(rendered, "\n") + 1; lines > 18 {
		t.Fatalf("compact QR uses %d rows", lines)
	}
	if !strings.ContainsAny(rendered, "⣿⠿⣶⣤⡀") {
		t.Fatalf("compact QR did not use braille cells: %q", rendered)
	}
}

func TestEmbeddedLoginFlow(t *testing.T) {
	img := image.NewGray(image.Rect(0, 0, 29, 29))
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		t.Fatal(err)
	}
	model := New(source.NewMixed(authDemo{Provider: demo.New(), image: encoded.Bytes()}), time.Second)
	model.filterIndex = 1
	updated, _ := model.Update(tea.WindowSizeMsg{Width: 80, Height: 30})
	model = updated.(Model)
	updated, command := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'L'}})
	model = updated.(Model)
	if command == nil {
		t.Fatal("login key did not request a QR code")
	}
	updated, poll := model.Update(command())
	model = updated.(Model)
	if model.mode != loginView || len(model.loginImage) == 0 || poll == nil {
		t.Fatalf("login view was not opened: %+v", model)
	}
	updated, refresh := model.Update(loginStatusMsg{status: source.LoginStatus{LoggedIn: true, Username: "alice"}})
	model = updated.(Model)
	if model.mode != listView || !strings.Contains(model.status, "alice") || refresh == nil {
		t.Fatalf("successful login was not applied: %+v", model)
	}
}

func TestTiebaCredentialLoginIsMasked(t *testing.T) {
	provider := &credentialDemo{Provider: demo.New()}
	model := New(source.NewMixed(provider), time.Second)
	model.filterIndex = 1
	updated, command := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'L'}})
	model = updated.(Model)
	if command == nil || model.inputMode != inputTiebaCredential || model.input.EchoMode != textinput.EchoPassword {
		t.Fatalf("Tieba credential input was not opened and masked: %+v", model)
	}
	credential := strings.Repeat("x", 192)
	model.input.SetValue(credential)
	updated, login := model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(Model)
	if login == nil {
		t.Fatal("credential was not submitted")
	}
	updated, refresh := model.Update(login())
	model = updated.(Model)
	if provider.credential != credential || !strings.Contains(model.status, "bob") || refresh == nil {
		t.Fatalf("credential login was not applied: status=%q credential=%q", model.status, provider.credential)
	}
}

func TestSourceSpecificLoginHelp(t *testing.T) {
	provider := &credentialDemo{Provider: demo.New()}
	xhs := authDemo{Provider: demo.New()}
	model := New(source.NewMixed(provider, xhs), time.Second)
	model.filterIndex = 1
	if help := model.listHelp(); !strings.Contains(help, "贴吧扫码") || !strings.Contains(help, "BDUSS") {
		t.Fatalf("Tieba help = %q", help)
	}
	model.filterIndex = 2
	if help := model.listHelp(); !strings.Contains(help, "小红书扫码") || strings.Contains(help, "BDUSS") {
		t.Fatalf("XHS help = %q", help)
	}
}

func TestLoginPressedDuringSourceSwitchIsQueuedForNewSource(t *testing.T) {
	img := image.NewGray(image.Rect(0, 0, 29, 29))
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		t.Fatal(err)
	}
	tiebaProvider := &credentialDemo{Provider: demo.New()}
	xhsProvider := authDemo{Provider: demo.New(), image: encoded.Bytes()}
	model := New(source.NewMixed(tiebaProvider, xhsProvider), time.Second)
	model.filterIndex = 1
	model.busy = true

	updated, _ := model.Update(tea.KeyMsg{Type: tea.KeyTab})
	model = updated.(Model)
	if model.filterIndex != 2 || !model.reloadAfterBusy {
		t.Fatalf("source switch was not queued: %+v", model)
	}
	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'L'}})
	model = updated.(Model)
	if !model.loginAfterBusy {
		t.Fatal("login was not queued while source was loading")
	}
	updated, command := model.Update(pageMsg{page: domain.Page{}})
	model = updated.(Model)
	if command == nil || model.loginSource != domain.SourceXHS {
		t.Fatalf("queued login target = %q, command nil = %v", model.loginSource, command == nil)
	}
	message := command()
	if _, ok := message.(loginQRMsg); !ok {
		t.Fatalf("queued command returned %T", message)
	}
}

func TestChannelKeys(t *testing.T) {
	model := New(source.NewMixed(demo.New()), time.Second)
	updated, command := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'2'}})
	model = updated.(Model)
	if model.currentChannel() != source.ChannelHot || command == nil {
		t.Fatalf("hot channel was not selected: %+v", model)
	}
	updated, _ = model.Update(command())
	model = updated.(Model)
	if len(model.items) == 0 || !strings.Contains(strings.Join(model.notices, " "), "热榜") {
		t.Fatalf("hot channel did not load: %+v", model)
	}
}
