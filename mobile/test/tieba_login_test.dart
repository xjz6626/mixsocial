import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _domain = 'https://tieba.baidu.com/';

void main() {
  test('builds a Go credential from WebView login cookies', () {
    final credential = tiebaCredentialFromCookies(const <WebViewCookie>[
      WebViewCookie(name: 'STOKEN', value: 'token-value', domain: _domain),
      WebViewCookie(name: 'BDUSS', value: 'bduss-value', domain: _domain),
      WebViewCookie(name: 'BAIDUID', value: 'ignored', domain: _domain),
    ]);

    expect(credential, 'BDUSS=bduss-value; STOKEN=token-value');
  });

  test('uses BDUSS_BFESS only when BDUSS is unavailable', () {
    final credential = tiebaCredentialFromCookies(const <WebViewCookie>[
      WebViewCookie(name: 'BDUSS_BFESS', value: 'bfess-value', domain: _domain),
      WebViewCookie(name: 'bduss', value: 'preferred', domain: _domain),
    ]);

    expect(credential, 'BDUSS=preferred');
  });

  test('returns null when the WebView has no Tieba credential', () {
    expect(
      tiebaCredentialFromCookies(const <WebViewCookie>[
        WebViewCookie(name: 'BAIDUID', value: 'value', domain: _domain),
      ]),
      isNull,
    );
  });
}
