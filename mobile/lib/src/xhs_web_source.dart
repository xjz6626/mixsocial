import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'models.dart';
import 'source.dart';
import 'xhs_scripts.dart';

class XhsWebSource
    implements FeedSource, ContentInteractor, RelationshipInteractor {
  XhsWebSource._(this.controller);

  static const _exploreUrl = 'https://www.xiaohongshu.com/explore';
  static const _desktopUserAgent =
      'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final WebViewController controller;
  Completer<Uri>? _pageFinished;
  Future<void> _operationTail = Future<void>.value();

  static Future<XhsWebSource> create() async {
    late final XhsWebSource source;
    final controller = WebViewController();
    source = XhsWebSource._(controller);
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setUserAgent(_desktopUserAgent);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (NavigationRequest request) {
          final uri = Uri.tryParse(request.url);
          return uri != null && source._allowed(uri)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onPageFinished: (String url) {
          final completer = source._pageFinished;
          if (completer != null && !completer.isCompleted) {
            completer.complete(Uri.parse(url));
          }
        },
        onWebResourceError: (WebResourceError error) {
          if (error.isForMainFrame != true) return;
          final completer = source._pageFinished;
          if (completer != null && !completer.isCompleted) {
            completer.completeError(
              StateError('小红书页面加载失败：${error.description}'),
            );
          }
        },
      ),
    );
    return source;
  }

  @override
  SourceId get id => SourceId.xhs;

  @override
  Set<SourceCapability> get capabilities => const <SourceCapability>{
    SourceCapability.feed,
    SourceCapability.search,
    SourceCapability.detail,
    SourceCapability.like,
    SourceCapability.favorite,
    SourceCapability.comment,
    SourceCapability.reply,
    SourceCapability.hot,
    SourceCapability.followingFeed,
    SourceCapability.login,
    SourceCapability.follow,
    SourceCapability.block,
  };

  Widget webView({Key? key}) => WebViewWidget(key: key, controller: controller);

  Future<void> openLogin() => _exclusive(() async {
    await _navigate(Uri.parse(_exploreUrl));
  });

  Future<void> openContentPage(ContentRef ref) => _exclusive(() async {
    _requireXhs(ref);
    await _navigate(_contentUri(ref));
  });

  Future<bool> isLoggedIn() => _exclusive(() async {
    await _navigate(Uri.parse(_exploreUrl));
    return _scriptBool(r'''(() => {
          const user = window.__INITIAL_STATE__?.user?.userInfo;
          const value = user?.value !== undefined ? user.value : user?._value !== undefined ? user._value : user;
          return !!value && value.guest !== true;
        })()''');
  });

  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) =>
      _exclusive(() async {
        await _navigate(Uri.parse(_exploreUrl));
        if (cursor.isNotEmpty) {
          await controller.scrollBy(0, 1800);
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
        if (channel == FeedChannel.following) {
          final activated = await _scriptBool(xhsActivateChannelScript('关注'));
          if (!activated) throw StateError('当前小红书网页没有可用的关注频道入口');
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
        var page = FeedPage.decode(await _waitForJson(xhsFeedScript));
        if (channel == FeedChannel.hot) {
          final items = List<FeedItem>.of(page.items)
            ..sort(
              (FeedItem left, FeedItem right) =>
                  _heat(right).compareTo(_heat(left)),
            );
          page = FeedPage(
            items: items,
            notices: const <String>['小红书网页没有官方全站热榜，当前按本次推荐样本的互动量排序'],
          );
        }
        return page;
      });

  @override
  Future<FeedPage> search(String query, {String cursor = ''}) =>
      _exclusive(() async {
        final keyword = query.trim();
        if (keyword.isEmpty) throw ArgumentError('请输入搜索词');
        final uri = Uri.https(
          'www.xiaohongshu.com',
          '/search_result',
          <String, String>{'keyword': keyword, 'source': 'web_explore_feed'},
        );
        await _navigate(uri);
        if (cursor.isNotEmpty) {
          await controller.scrollBy(0, 1800);
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
        return FeedPage.decode(
          await _waitForJson(
            xhsFeedScript.replaceAll('state.feed', 'state.search'),
          ),
        );
      });

  @override
  Future<FeedDetail> detail(ContentRef ref) => _exclusive(() async {
    _requireXhs(ref);
    await _navigate(_contentUri(ref));
    return FeedDetail.decode(
      await _waitForJson(xhsDetailScript(ref.id, ref.token), attempts: 40),
    );
  });

  @override
  Future<void> like(ContentRef ref, bool value) => _toggleContent(
    ref,
    field: 'liked',
    selector: '.interact-container .left .like-lottie',
    value: value,
    label: value ? '点赞' : '取消点赞',
  );

  @override
  Future<void> favorite(ContentRef ref, bool value) => _toggleContent(
    ref,
    field: 'collected',
    selector: '.interact-container .left .reds-icon.collect-icon',
    value: value,
    label: value ? '收藏' : '取消收藏',
  );

  @override
  Future<void> comment(ContentRef ref, String body) => _exclusive(() async {
    final content = body.trim();
    if (content.isEmpty) throw ArgumentError('评论不能为空');
    await _navigate(_contentUri(ref));
    if (!await _scriptBool(xhsCommentScript(content))) {
      throw StateError('小红书网页没有可用的评论输入框');
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!await _scriptBool(xhsSubmitCommentScript)) {
      throw StateError('小红书评论按钮不可用');
    }
    await _waitForBool(xhsCommentVisibleScript(content), label: '确认评论结果');
  });

  @override
  Future<void> reply(ContentRef ref, ContentRef comment, String body) =>
      _exclusive(() async {
        final content = body.trim();
        if (content.isEmpty) throw ArgumentError('回复不能为空');
        await _navigate(_contentUri(ref));
        if (!await _scriptBool(xhsReplyTargetScript(comment.id))) {
          throw StateError('当前已加载评论中没有找到回复目标');
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!await _scriptBool(xhsCommentScript(content))) {
          throw StateError('小红书回复输入框不可用');
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!await _scriptBool(xhsSubmitCommentScript)) {
          throw StateError('小红书回复按钮不可用');
        }
        await _waitForBool(xhsCommentVisibleScript(content), label: '确认回复结果');
      });

  @override
  Future<void> follow(ProfileRef profile, bool value) => _exclusive(() async {
    _requireXhsProfile(profile);
    await _navigate(_profileUri(profile));
    final state = await _scriptString(xhsFollowStateScript());
    if (state == value.toString()) return;
    if (!await _scriptBool(xhsClickFollowScript(value))) {
      throw StateError('小红书网页没有找到${value ? '关注' : '取消关注'}按钮');
    }
    if (!value) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _scriptBool(xhsConfirmUnfollowScript);
    }
    await _waitForString(
      xhsFollowStateScript(),
      value.toString(),
      label: '确认关注状态',
    );
  });

  @override
  Future<void> block(ProfileRef profile, bool value) => _exclusive(() async {
    _requireXhsProfile(profile);
    await _navigate(_profileUri(profile));
    if (!await _scriptBool(xhsOpenProfileMenuScript)) {
      throw StateError('小红书网页没有找到用户菜单');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!await _scriptBool(xhsClickBlockScript(value))) {
      throw StateError('小红书网页没有找到${value ? '屏蔽' : '解除屏蔽'}操作');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _scriptBool(xhsConfirmDangerousActionScript);
  });

  Future<void> _toggleContent(
    ContentRef ref, {
    required String field,
    required String selector,
    required bool value,
    required String label,
  }) => _exclusive(() async {
    _requireXhs(ref);
    await _navigate(_contentUri(ref));
    final current = await _scriptString(xhsInteractStateScript(ref.id, field));
    if (current == value.toString()) return;
    if (!await _scriptBool(xhsClickScript(selector))) {
      throw StateError('小红书网页没有找到$label按钮');
    }
    await _waitForString(
      xhsInteractStateScript(ref.id, field),
      value.toString(),
      label: '确认$label结果',
    );
  });

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final task = _operationTail.then<T>((_) => operation());
    _operationTail = task.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return task;
  }

  Future<void> _navigate(Uri uri) async {
    if (!_allowed(uri)) throw StateError('已阻止非小红书页面：$uri');
    final completer = Completer<Uri>();
    _pageFinished = completer;
    await controller.loadRequest(uri);
    await completer.future.timeout(const Duration(seconds: 45));
  }

  Future<String> _waitForJson(String script, {int attempts = 24}) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      final value = await _scriptString(script);
      if (value.startsWith('{') || value.startsWith('[')) return value;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw TimeoutException('等待小红书页面数据超时');
  }

  Future<void> _waitForBool(String script, {required String label}) async {
    for (var attempt = 0; attempt < 16; attempt++) {
      if (await _scriptBool(script)) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw StateError('$label失败');
  }

  Future<void> _waitForString(
    String script,
    String expected, {
    required String label,
  }) async {
    for (var attempt = 0; attempt < 16; attempt++) {
      if (await _scriptString(script) == expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw StateError('$label失败');
  }

  Future<bool> _scriptBool(String script) async {
    final result = await controller.runJavaScriptReturningResult(script);
    if (result is bool) return result;
    return _decodeScriptString(result) == 'true';
  }

  Future<String> _scriptString(String script) async {
    final result = await controller.runJavaScriptReturningResult(script);
    return _decodeScriptString(result);
  }

  String _decodeScriptString(Object result) {
    if (result is! String) return result.toString();
    try {
      final decoded = jsonDecode(result);
      return decoded is String ? decoded : result;
    } on FormatException {
      return result;
    }
  }

  bool _allowed(Uri uri) =>
      uri.scheme == 'https' &&
      (uri.host == 'xiaohongshu.com' || uri.host.endsWith('.xiaohongshu.com'));

  Uri _contentUri(ContentRef ref) => ref.url.isNotEmpty
      ? Uri.parse(ref.url)
      : Uri.https('www.xiaohongshu.com', '/explore/${ref.id}', <String, String>{
          'xsec_token': ref.token,
          'xsec_source': 'pc_feed',
        });

  Uri _profileUri(ProfileRef ref) => ref.url.isNotEmpty
      ? Uri.parse(ref.url)
      : Uri.https(
          'www.xiaohongshu.com',
          '/user/profile/${ref.id}',
          <String, String>{'xsec_token': ref.token, 'xsec_source': 'pc_note'},
        );

  void _requireXhs(ContentRef ref) {
    if (ref.source != SourceId.xhs || ref.id.isEmpty) {
      throw ArgumentError('无效的小红书内容引用');
    }
  }

  void _requireXhsProfile(ProfileRef ref) {
    if (ref.source != SourceId.xhs || ref.id.isEmpty) {
      throw ArgumentError('无效的小红书用户引用');
    }
  }

  int _heat(FeedItem item) =>
      item.stats.likes +
      item.stats.favorites * 2 +
      item.stats.comments * 3 +
      item.stats.shares * 2;
}
