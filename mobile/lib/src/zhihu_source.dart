import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mixsocial_core/mixsocial_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'models.dart';
import 'source.dart';
import 'source_diagnostics.dart';

class ZhihuSource implements FeedSource, ContentInteractor, ThreadPageReader {
  ZhihuSource._(this._secureStorage, {this.enabled = true});

  static const _credentialKey = 'zhihu.cookie';
  static final _webCookieDomains = <Uri>[
    Uri.parse('https://www.zhihu.com/'),
    Uri.parse('https://zhihu.com/'),
    Uri.parse('https://api.zhihu.com/'),
  ];

  final FlutterSecureStorage _secureStorage;
  final bool enabled;
  TiebaSessionStatus _sessionStatus = const TiebaSessionStatus(
    TiebaSessionState.signedOut,
  );
  Future<TiebaSessionStatus>? _loginCheck;

  TiebaSessionStatus get sessionStatus => _sessionStatus;

  static ZhihuSource unavailable() =>
      ZhihuSource._(const FlutterSecureStorage(), enabled: false);

  static Future<ZhihuSource> create({
    FlutterSecureStorage? secureStorage,
  }) async {
    final storage = secureStorage ?? const FlutterSecureStorage();
    final source = ZhihuSource._(storage);
    await MixsocialCore.configureZhihu();
    final credential = await storage.read(key: _credentialKey);
    if (credential != null && credential.isNotEmpty) {
      try {
        source._sessionStatus = TiebaSessionStatus.fromResponse(
          mapOf(jsonDecode(await MixsocialCore.loginZhihu(credential))),
        );
      } catch (error) {
        source._sessionStatus = TiebaSessionStatus.fromFailure(error);
        sourceDiagnostics.record(SourceId.zhihu, '登录验证', error);
        // Keep the cookie through transient network or risk-control failures.
      }
    }
    return source;
  }

  @override
  SourceId get id => SourceId.zhihu;

  @override
  Set<SourceCapability> get capabilities => const <SourceCapability>{
    SourceCapability.feed,
    SourceCapability.search,
    SourceCapability.detail,
    SourceCapability.like,
    SourceCapability.comment,
    SourceCapability.reply,
    SourceCapability.hot,
    SourceCapability.followingFeed,
    SourceCapability.login,
  };

  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) async {
    _requireEnabled();
    return FeedPage.decode(await MixsocialCore.browseZhihu(channel.id, cursor));
  }

  @override
  Future<FeedPage> search(String query, {String cursor = ''}) async {
    _requireEnabled();
    return FeedPage.decode(await MixsocialCore.searchZhihu(query, cursor));
  }

  @override
  Future<FeedDetail> detail(ContentRef ref) async {
    _validateRef(ref);
    return FeedDetail.decode(
      await MixsocialCore.zhihuDetail(jsonEncode(ref.toJson())),
    );
  }

  @override
  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) async {
    _validateRef(ref);
    if (cursor.isEmpty) return detail(ref);
    final page = FeedCommentPage.decode(
      await MixsocialCore.zhihuComments(jsonEncode(ref.toJson()), cursor),
      source: SourceId.zhihu,
    );
    return FeedDetail(
      item: FeedItem(
        ref: ref,
        title: '',
        author: const Author(
          ref: ProfileRef(source: SourceId.zhihu, id: ''),
          id: '',
          name: '未知用户',
        ),
        stats: const ItemStats(),
      ),
      body: '',
      comments: page.comments,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
    );
  }

  @override
  Future<void> like(ContentRef ref, bool value) async {
    _validateRef(ref);
    await MixsocialCore.likeZhihu(jsonEncode(ref.toJson()), value);
  }

  @override
  Future<void> favorite(ContentRef ref, bool value) async {
    throw StateError('知乎暂不支持选择收藏夹；可使用本地收藏');
  }

  @override
  Future<void> comment(ContentRef ref, String body) async {
    _validateRef(ref);
    await MixsocialCore.commentZhihu(jsonEncode(ref.toJson()), body);
  }

  @override
  Future<void> reply(ContentRef ref, ContentRef comment, String body) async {
    _validateRef(ref);
    if (comment.source != SourceId.zhihu || comment.id.trim().isEmpty) {
      throw ArgumentError('知乎回复目标无效');
    }
    await MixsocialCore.replyZhihu(
      jsonEncode(ref.toJson()),
      jsonEncode(comment.toJson()),
      body,
    );
  }

  Future<void> loginWithCredential(String credential) async {
    _requireEnabled();
    final value = credential.trim();
    if (value.isEmpty) throw ArgumentError('知乎 Cookie 不能为空');
    _sessionStatus = TiebaSessionStatus.fromResponse(
      mapOf(jsonDecode(await MixsocialCore.loginZhihu(value))),
    );
    if (!_sessionStatus.verified) throw StateError('知乎未确认登录成功');
    await _secureStorage.write(key: _credentialKey, value: value);
  }

  Future<TiebaSessionStatus> checkLogin() {
    if (!enabled) {
      return Future<TiebaSessionStatus>.value(
        const TiebaSessionStatus(TiebaSessionState.signedOut),
      );
    }
    if (_loginCheck != null) return _loginCheck!;
    final check = _checkLogin();
    _loginCheck = check;
    return check.whenComplete(() => _loginCheck = null);
  }

  Future<TiebaSessionStatus> _checkLogin() async {
    try {
      final value = await _secureStorage.read(key: _credentialKey);
      if (value == null || value.isEmpty) {
        return _sessionStatus = const TiebaSessionStatus(
          TiebaSessionState.signedOut,
        );
      }
      _sessionStatus = TiebaSessionStatus.fromResponse(
        mapOf(jsonDecode(await MixsocialCore.zhihuLoginStatus())),
      );
      if (!_sessionStatus.verified) {
        _sessionStatus = TiebaSessionStatus.fromResponse(
          mapOf(jsonDecode(await MixsocialCore.loginZhihu(value))),
        );
      }
    } catch (error) {
      _sessionStatus = TiebaSessionStatus.fromFailure(error);
      sourceDiagnostics.record(SourceId.zhihu, '登录验证', error);
    }
    return _sessionStatus;
  }

  Future<bool> loginFromWebViewCookies() async {
    _requireEnabled();
    final manager = WebViewCookieManager();
    final groups = await Future.wait<List<WebViewCookie>>(
      _webCookieDomains.map((Uri domain) => manager.getCookies(domain: domain)),
    );
    final credential = zhihuCredentialFromCookies(
      groups.expand((items) => items),
    );
    if (credential == null) return false;
    await loginWithCredential(credential);
    return true;
  }

  Future<bool> hasCredential() async {
    if (!enabled) return false;
    final value = await _secureStorage.read(key: _credentialKey);
    return value != null && value.isNotEmpty;
  }

  Future<void> logout() async {
    if (!enabled) return;
    await MixsocialCore.clearZhihuCredential();
    _sessionStatus = const TiebaSessionStatus(TiebaSessionState.signedOut);
    await _secureStorage.delete(key: _credentialKey);
  }

  void _validateRef(ContentRef ref) {
    _requireEnabled();
    if (ref.source != SourceId.zhihu || ref.id.trim().isEmpty) {
      throw ArgumentError('无效的知乎内容引用');
    }
  }

  void _requireEnabled() {
    if (!enabled) throw StateError('知乎移动核心尚未启用');
  }
}

String? zhihuCredentialFromCookies(Iterable<WebViewCookie> cookies) {
  final values = <String, String>{};
  for (final cookie in cookies) {
    final name = cookie.name.trim().toLowerCase();
    final value = cookie.value.trim();
    if (value.isNotEmpty && const {'_xsrf', 'd_c0', 'z_c0'}.contains(name)) {
      values[name] = value;
    }
  }
  if (const {
    '_xsrf',
    'd_c0',
    'z_c0',
  }.any((name) => !values.containsKey(name))) {
    return null;
  }
  return <String>[
    '_xsrf=${values['_xsrf']}',
    'd_c0=${values['d_c0']}',
    'z_c0=${values['z_c0']}',
  ].join('; ');
}
