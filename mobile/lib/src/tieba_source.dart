import 'dart:convert';
import 'dart:ui';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mixsocial_core/mixsocial_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'models.dart';
import 'source.dart';
import 'source_diagnostics.dart';

class TiebaSource
    implements
        FeedSource,
        ForumReader,
        ThreadPageReader,
        FloorReplyReader,
        ProfileReader {
  TiebaSource._(this._secureStorage);

  static const _credentialKey = 'tieba.bduss';
  static final _webCookieDomains = <Uri>[
    Uri.parse('https://tieba.baidu.com/'),
    Uri.parse('https://passport.baidu.com/'),
  ];
  final FlutterSecureStorage _secureStorage;
  TiebaSessionStatus _sessionStatus = const TiebaSessionStatus(
    TiebaSessionState.signedOut,
  );
  TiebaSessionStatus get sessionStatus => _sessionStatus;
  Future<TiebaSessionStatus>? _loginCheck;
  Future<void> _startup = Future<void>.value();

  static Future<TiebaSource> create({
    List<String> forums = const <String>[],
  }) async {
    const storage = FlutterSecureStorage();
    final source = TiebaSource._(storage);
    await MixsocialCore.configureTieba(forums: forums);
    // Credential validation can take a full network round trip. Let the app
    // paint cached content first; source operations wait for this future in
    // the background before touching the native client.
    source._startup = source._restoreStoredCredential();
    return source;
  }

  Future<void> _restoreStoredCredential() async {
    try {
      final credential = await _secureStorage.read(key: _credentialKey);
      if (credential != null && credential.isNotEmpty) {
        _sessionStatus = TiebaSessionStatus.fromResponse(
          mapOf(jsonDecode(await MixsocialCore.loginTieba(credential))),
        );
      }
    } catch (error) {
      _sessionStatus = TiebaSessionStatus.fromFailure(error);
      sourceDiagnostics.record(SourceId.tieba, '登录验证', error);
      // Keep the credential so a transient network failure does not log the
      // user out. The login screen can replace or explicitly clear it.
    }
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
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) async {
    await _startup;
    return FeedPage.decode(await MixsocialCore.browseTieba(channel.id, cursor));
  }

  @override
  Future<FeedPage> search(String query, {String cursor = ''}) async {
    await _startup;
    return FeedPage.decode(await MixsocialCore.searchTieba(query, cursor));
  }

  @override
  Future<FeedDetail> detail(ContentRef ref) async {
    await _startup;
    return FeedDetail.decode(
      await MixsocialCore.tiebaDetail(jsonEncode(ref.toJson())),
    );
  }

  @override
  Future<FeedPage> forum(
    String forum, {
    String cursor = '',
    int sortType = 0,
  }) async {
    await _startup;
    return FeedPage.decode(
      await MixsocialCore.forumTieba(forum, cursor, sortType: sortType),
    );
  }

  @override
  Future<FeedPage> searchForum(
    String forum,
    String query, {
    String cursor = '',
  }) async {
    await _startup;
    return FeedPage.decode(
      await MixsocialCore.searchForumTieba(forum, query, cursor),
    );
  }

  @override
  Future<List<String>> followingForums() async {
    await _startup;
    return (jsonDecode(await MixsocialCore.followingForumsTieba())
            as List<Object?>)
        .map((Object? value) => value.toString())
        .where((String value) => value.isNotEmpty)
        .toList();
  }

  @override
  Future<ProfilePage> profile(
    ProfileRef profile, {
    ProfileSection section = ProfileSection.notes,
    String cursor = '',
  }) async {
    await _startup;
    if (profile.source != SourceId.tieba ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(profile.id)) {
      throw ArgumentError('无效的贴吧用户编号');
    }
    if (section != ProfileSection.notes) {
      throw StateError('贴吧主页暂时仅提供公开帖子动态；平台收藏和点赞请到官方网页查看');
    }
    try {
      return ProfilePage.decode(
        await MixsocialCore.profileTieba(
          jsonEncode(profile.toJson()),
          cursor: cursor,
        ),
      );
    } catch (error) {
      sourceDiagnostics.record(SourceId.tieba, '作者主页', error);
      throw StateError(SourceFailure.from(error).message);
    }
  }

  Future<Author> currentProfile() async {
    final status = await checkLogin();
    if (!status.verified) throw StateError(status.label);
    return Author(
      ref: ProfileRef(source: SourceId.tieba, id: status.userId),
      id: status.userId,
      name: status.username.isEmpty ? '我的贴吧主页' : status.username,
    );
  }

  @override
  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) async {
    await _startup;
    return FeedDetail.decode(
      await MixsocialCore.tiebaDetailPage(
        jsonEncode(ref.toJson()),
        cursor,
        reverse: reverse,
        onlyOriginalPoster: onlyOriginalPoster,
      ),
    );
  }

  @override
  Future<FeedCommentPage> floorReplies(
    ContentRef floor, {
    String cursor = '',
  }) async {
    await _startup;
    return FeedCommentPage.decode(
      await MixsocialCore.floorRepliesTieba(jsonEncode(floor.toJson()), cursor),
    );
  }

  Future<WebViewController> interactionController(ContentRef ref) async {
    if (ref.source != SourceId.tieba || ref.id.trim().isEmpty) {
      throw ArgumentError('无效的贴吧帖子引用');
    }
    await _restoreInteractionCookies();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            final uri = Uri.tryParse(request.url);
            final allowed =
                uri != null &&
                (uri.scheme == 'https' || uri.scheme == 'http') &&
                (uri.host == 'baidu.com' || uri.host.endsWith('.baidu.com'));
            return allowed
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );
    final supplied = Uri.tryParse(ref.url);
    final uri =
        supplied != null &&
            (supplied.host == 'tieba.baidu.com' ||
                supplied.host.endsWith('.tieba.baidu.com'))
        ? supplied.replace(scheme: 'https')
        : Uri.https('tieba.baidu.com', '/p/${ref.id}');
    await controller.loadRequest(uri);
    return controller;
  }

  Future<void> _restoreInteractionCookies() async {
    final credential = await _secureStorage.read(key: _credentialKey);
    if (credential == null || credential.trim().isEmpty) return;
    final values = <String, String>{};
    for (final part in credential.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      values[part.substring(0, separator).trim().toUpperCase()] = part
          .substring(separator + 1)
          .trim();
    }
    final rawBduss = values['BDUSS'] ?? credential.trim();
    if (rawBduss.isNotEmpty) {
      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: 'BDUSS',
          value: rawBduss,
          domain: 'tieba.baidu.com',
          path: '/',
        ),
      );
    }
    final stoken = values['STOKEN'];
    if (stoken != null && stoken.isNotEmpty) {
      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: 'STOKEN',
          value: stoken,
          domain: 'tieba.baidu.com',
          path: '/',
        ),
      );
    }
  }

  Future<void> loginWithCredential(String credential) async {
    await _startup;
    final value = credential.trim();
    if (value.isEmpty) throw ArgumentError('BDUSS 不能为空');
    _sessionStatus = TiebaSessionStatus.fromResponse(
      mapOf(jsonDecode(await MixsocialCore.loginTieba(value))),
    );
    if (!_sessionStatus.verified) throw StateError('贴吧未确认登录成功');
    await _secureStorage.write(key: _credentialKey, value: value);
  }

  Future<TiebaSessionStatus> checkLogin() {
    if (_loginCheck != null) return _loginCheck!;
    final check = _checkLogin();
    _loginCheck = check;
    return check.whenComplete(() => _loginCheck = null);
  }

  Future<TiebaSessionStatus> _checkLogin() async {
    await _startup;
    try {
      final value = await _secureStorage.read(key: _credentialKey);
      if (value == null || value.isEmpty) {
        return _sessionStatus = const TiebaSessionStatus(
          TiebaSessionState.signedOut,
        );
      }
      _sessionStatus = TiebaSessionStatus.fromResponse(
        mapOf(jsonDecode(await MixsocialCore.loginTieba(value))),
      );
    } catch (error) {
      _sessionStatus = TiebaSessionStatus.fromFailure(error);
      sourceDiagnostics.record(SourceId.tieba, '登录验证', error);
    }
    return _sessionStatus;
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

  /// Only used by the user-initiated, end-to-end encrypted device transfer.
  Future<String?> exportCredentialForTransfer() async {
    final value = (await _secureStorage.read(key: _credentialKey))?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// Persists first so a temporary network failure cannot lose the transfer.
  Future<void> importCredentialFromTransfer(String credential) async {
    await _startup;
    final value = credential.trim();
    if (value.isEmpty ||
        value.length > 8192 ||
        value.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('贴吧登录凭据无效');
    }
    await _secureStorage.write(key: _credentialKey, value: value);
    try {
      _sessionStatus = TiebaSessionStatus.fromResponse(
        mapOf(jsonDecode(await MixsocialCore.loginTieba(value))),
      );
    } catch (error) {
      _sessionStatus = TiebaSessionStatus.fromFailure(error);
      sourceDiagnostics.record(SourceId.tieba, '迁移后登录验证', error);
    }
  }

  Future<void> logout() async {
    await _startup;
    await MixsocialCore.clearTiebaCredential();
    _sessionStatus = const TiebaSessionStatus(TiebaSessionState.signedOut);
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
