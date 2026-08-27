import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mixsocial_core/mixsocial_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'models.dart';
import 'source.dart';

class TiebaSource implements FeedSource {
  TiebaSource._(this._secureStorage);

  static const _credentialKey = 'tieba.bduss';
  static final _webCookieDomains = <Uri>[
    Uri.parse('https://tieba.baidu.com/'),
    Uri.parse('https://passport.baidu.com/'),
  ];
  final FlutterSecureStorage _secureStorage;

  static Future<TiebaSource> create({
    List<String> forums = const <String>[],
  }) async {
    const storage = FlutterSecureStorage();
    final source = TiebaSource._(storage);
    await MixsocialCore.configureTieba(forums: forums);
    final credential = await storage.read(key: _credentialKey);
    if (credential != null && credential.isNotEmpty) {
      try {
        await MixsocialCore.loginTieba(credential);
      } catch (_) {
        // Keep the credential so a transient network failure does not log the
        // user out. The login screen can replace or explicitly clear it.
      }
    }
    return source;
  }

  @override
  SourceId get id => SourceId.tieba;

  @override
  Set<SourceCapability> get capabilities => const <SourceCapability>{
    SourceCapability.feed,
    SourceCapability.search,
    SourceCapability.detail,
    SourceCapability.hot,
    SourceCapability.followingFeed,
    SourceCapability.login,
  };

  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) async =>
      FeedPage.decode(await MixsocialCore.browseTieba(channel.id, cursor));

  @override
  Future<FeedPage> search(String query, {String cursor = ''}) async =>
      FeedPage.decode(await MixsocialCore.searchTieba(query, cursor));

  @override
  Future<FeedDetail> detail(ContentRef ref) async => FeedDetail.decode(
    await MixsocialCore.tiebaDetail(jsonEncode(ref.toJson())),
  );

  Future<void> loginWithCredential(String credential) async {
    final value = credential.trim();
    if (value.isEmpty) throw ArgumentError('BDUSS 不能为空');
    await MixsocialCore.loginTieba(value);
    await _secureStorage.write(key: _credentialKey, value: value);
  }

  Future<bool> loginFromWebViewCookies() async {
    final manager = WebViewCookieManager();
    final cookieGroups = await Future.wait<List<WebViewCookie>>(
      _webCookieDomains.map((Uri domain) => manager.getCookies(domain: domain)),
    );
    final credential = tiebaCredentialFromCookies(
      cookieGroups.expand((items) => items),
    );
    if (credential == null) return false;
    await loginWithCredential(credential);
    return true;
  }

  Future<bool> hasCredential() async {
    final value = await _secureStorage.read(key: _credentialKey);
    return value != null && value.isNotEmpty;
  }

  Future<void> logout() async {
    await MixsocialCore.clearTiebaCredential();
    await _secureStorage.delete(key: _credentialKey);
  }
}

String? tiebaCredentialFromCookies(Iterable<WebViewCookie> cookies) {
  var bduss = '';
  var bdussBfess = '';
  var stoken = '';
  for (final cookie in cookies) {
    final value = cookie.value.trim();
    if (value.isEmpty) continue;
    switch (cookie.name.trim().toUpperCase()) {
      case 'BDUSS':
        bduss = value;
      case 'BDUSS_BFESS':
        bdussBfess = value;
      case 'STOKEN':
        stoken = value;
    }
  }
  final effectiveBduss = bduss.isNotEmpty ? bduss : bdussBfess;
  if (effectiveBduss.isEmpty) return null;
  return <String>[
    'BDUSS=$effectiveBduss',
    if (stoken.isNotEmpty) 'STOKEN=$stoken',
  ].join('; ');
}
