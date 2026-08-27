//go:build android || ios

package tieba

import (
	"context"
	"fmt"

	"github.com/xjz6626/mixsocial/internal/source"
)

// browserLoginSession is a placeholder for Provider's cross-platform layout.
// Mobile login belongs to the host WebView and passes the resulting credential
// to LoginWithCredential; Rod and a bundled Chromium are not linked.
type browserLoginSession struct{}

func browserLoginCapability() source.Capability { return 0 }

func (p *Provider) LoginQRCode(context.Context) (source.LoginChallenge, error) {
	return source.LoginChallenge{}, fmt.Errorf("移动端扫码登录由系统 WebView 提供")
}

func (p *Provider) browserLoginStatus(context.Context) (source.LoginStatus, bool, error) {
	return source.LoginStatus{}, false, nil
}

func (p *Provider) Close() error { return nil }
