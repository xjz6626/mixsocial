import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/zhihu_source.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _domain = 'https://www.zhihu.com/';

void main() {
  test('builds a minimal Zhihu credential from WebView cookies', () {
    final credential = zhihuCredentialFromCookies(const <WebViewCookie>[
      WebViewCookie(name: 'z_c0', value: 'zc=value', domain: _domain),
      WebViewCookie(name: '_xsrf', value: 'xsrf-value', domain: _domain),
      WebViewCookie(name: 'd_c0', value: 'dc-value', domain: _domain),
      WebViewCookie(name: 'SESSIONID', value: 'ignored', domain: _domain),
    ]);

    expect(credential, '_xsrf=xsrf-value; d_c0=dc-value; z_c0=zc=value');
  });

  test('cookie names are case insensitive and later values win', () {
    final credential = zhihuCredentialFromCookies(const <WebViewCookie>[
      WebViewCookie(name: 'Z_C0', value: 'old', domain: _domain),
      WebViewCookie(name: 'z_c0', value: 'new', domain: _domain),
      WebViewCookie(name: '_XSRF', value: 'xs', domain: _domain),
      WebViewCookie(name: 'D_C0', value: 'dc', domain: _domain),
    ]);

    expect(credential, contains('z_c0=new'));
  });

  test('returns null unless all required cookies are present', () {
    expect(
      zhihuCredentialFromCookies(const <WebViewCookie>[
        WebViewCookie(name: 'z_c0', value: 'zc', domain: _domain),
        WebViewCookie(name: '_xsrf', value: 'xs', domain: _domain),
      ]),
      isNull,
    );
  });
}
