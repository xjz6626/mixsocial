import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'models.dart';
import 'source.dart';
import 'xhs_scripts.dart';

class XhsSearchFilters {
  const XhsSearchFilters({
    this.sortBy = '综合',
    this.noteType = '不限',
    this.publishTime = '不限',
    this.searchScope = '不限',
    this.location = '不限',
  });

  final String sortBy;
  final String noteType;
  final String publishTime;
  final String searchScope;
  final String location;

  bool get isDefault =>
      sortBy == '综合' &&
      noteType == '不限' &&
      publishTime == '不限' &&
      searchScope == '不限' &&
      location == '不限';

  String get key => '$sortBy|$noteType|$publishTime|$searchScope|$location';

  Map<String, String> get selections => <String, String>{
    '排序依据': sortBy,
    '笔记类型': noteType,
    '发布时间': publishTime,
    '搜索范围': searchScope,
    '位置距离': location,
  };

  XhsSearchFilters copyWith({
    String? sortBy,
    String? noteType,
    String? publishTime,
    String? searchScope,
    String? location,
  }) => XhsSearchFilters(
    sortBy: sortBy ?? this.sortBy,
    noteType: noteType ?? this.noteType,
    publishTime: publishTime ?? this.publishTime,
    searchScope: searchScope ?? this.searchScope,
    location: location ?? this.location,
  );
}

class XhsWebSource
    implements
        FeedSource,
        ThreadPageReader,
        FloorReplyReader,
        ProfileReader,
        ContentInteractor,
        RelationshipInteractor {
  XhsWebSource._(this.controller);

  static const _exploreUrl = 'https://www.xiaohongshu.com/explore';
  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final WebViewController controller;
  Completer<Uri>? _pageFinished;
  Future<void> _operationTail = Future<void>.value();
  String? _activeListKey;
  String? _activeDetailId;
  int _detailCommentCount = 0;
  String? _activeProfileKey;
  int _profileItemCount = 0;
  XhsSearchFilters _searchFilters = const XhsSearchFilters();
  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  XhsSearchFilters get searchFilters => _searchFilters;

  void setSearchFilters(XhsSearchFilters value) {
    if (_searchFilters.key == value.key) return;
    _searchFilters = value;
    _activeListKey = null;
  }

  static Future<XhsWebSource> create() async {
    late final XhsWebSource source;
    final controller = WebViewController();
    source = XhsWebSource._(controller);
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setUserAgent(_desktopUserAgent);
    await controller.enableZoom(true);
    await controller.setBackgroundColor(const Color(0xFFFFFFFF));
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setUseWideViewPort(true);
      await platform.setMixedContentMode(MixedContentMode.alwaysAllow);
      await platform.setMediaPlaybackRequiresUserGesture(false);
    }
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (NavigationRequest request) {
          final uri = Uri.tryParse(request.url);
          return uri != null && source._allowed(uri)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onPageFinished: (String url) {
          unawaited(source._desktopizePage());
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
  };

  Widget webView({Key? key}) => WebViewWidget(key: key, controller: controller);

  Future<void> openLogin() => _exclusive(() async {
    await _navigate(Uri.parse(_exploreUrl));
    await _desktopizePage();
    for (var attempt = 0; attempt < 12; attempt++) {
      final state = await _scriptString(xhsOpenLoginScript);
      if (state == 'loggedIn' || state == 'ready') return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  });

  Future<void> openContentPage(ContentRef ref) => _exclusive(() async {
    _requireXhs(ref);
    await _navigate(_contentUri(ref));
  });

  Future<bool> isLoggedIn() => _exclusive(() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (await _scriptBool(xhsLoginStatusScript)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (await _scriptBool(
      "document.querySelector('.login-container .qrcode-img') !== null",
    )) {
      return false;
    }
    try {
      final cookies = await _cookieManager.getCookies(
        domain: Uri.parse('https://www.xiaohongshu.com'),
      );
      return cookies.any(
        (WebViewCookie cookie) =>
            cookie.name == 'web_session' && cookie.value.isNotEmpty,
      );
    } on UnimplementedError {
      return false;
    }
  });

  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) =>
      _exclusive(() async {
        final listKey = 'browse:${channel.id}';
        if (cursor.isEmpty || _activeListKey != listKey) {
          await _navigate(Uri.parse(_exploreUrl));
          if (channel == FeedChannel.following) {
            final activated = await _scriptBool(xhsActivateChannelScript('关注'));
            if (!activated) throw StateError('当前小红书网页没有可用的关注频道入口');
            await Future<void>.delayed(const Duration(milliseconds: 900));
          }
          _activeListKey = listKey;
        }
        if (cursor.isNotEmpty) {
          await controller.scrollBy(0, 1800);
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
        var page = _scrollablePage(
          FeedPage.decode(await _waitForJson(xhsFeedScript)),
        );
        if (channel == FeedChannel.hot) {
          final items = List<FeedItem>.of(page.items)
            ..sort(
              (FeedItem left, FeedItem right) =>
                  _heat(right).compareTo(_heat(left)),
            );
          page = FeedPage(
            items: items,
            nextCursor: 'more',
            hasMore: items.isNotEmpty,
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
        final listKey = 'search:$keyword:${_searchFilters.key}';
        if (cursor.isEmpty || _activeListKey != listKey) {
          await _navigate(uri);
          await _applySearchFilters();
          _activeListKey = listKey;
        }
        if (cursor.isNotEmpty) {
          await controller.scrollBy(0, 1800);
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
        return _scrollablePage(
          FeedPage.decode(
            await _waitForJson(
              xhsFeedScript.replaceAll('state.feed', 'state.search'),
            ),
          ),
        );
      });

  @override
  Future<FeedDetail> detail(ContentRef ref) => detailPage(ref);

  @override
  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) => _exclusive(() async {
    _requireXhs(ref);
    if (reverse || onlyOriginalPoster) {
      throw StateError('小红书评论页不支持倒序或只看作者');
    }
    if (cursor.isEmpty || _activeDetailId != ref.id) {
      await _navigate(_contentUri(ref));
      _activeDetailId = ref.id;
      _detailCommentCount = 0;
    } else {
      await _loadMoreComments();
    }
    final detail = FeedDetail.decode(
      await _waitForJson(xhsDetailScript(ref.id, ref.token), attempts: 40),
    );
    final madeProgress =
        cursor.isEmpty || detail.comments.length > _detailCommentCount;
    _detailCommentCount = detail.comments.length;
    return FeedDetail(
      item: detail.item,
      body: detail.body,
      comments: detail.comments,
      nextCursor: detail.nextCursor,
      hasMore: detail.hasMore && madeProgress,
    );
  });

  @override
  Future<FeedCommentPage> floorReplies(
    ContentRef floor, {
    String cursor = '',
  }) => _exclusive(() async {
    _requireXhs(floor);
    if (floor.parentId.isEmpty) throw ArgumentError('小红书评论缺少笔记 ID');
    if (_activeDetailId != floor.parentId) {
      final note = ContentRef(
        source: SourceId.xhs,
        id: floor.parentId,
        token: floor.token,
      );
      await _navigate(_contentUri(note));
      _activeDetailId = floor.parentId;
      _detailCommentCount = 0;
    }
    if (cursor.isNotEmpty) {
      final clicked = await _scriptBool(
        xhsLoadMoreFloorRepliesScript(floor.id),
      );
      if (clicked) {
        await Future<void>.delayed(const Duration(milliseconds: 850));
      }
    }
    final raw = await _waitForJson(
      xhsFloorRepliesScript(floor.parentId, floor.id),
      attempts: 24,
    );
    return FeedCommentPage.decode(raw, source: SourceId.xhs);
  });

  @override
  Future<ProfilePage> profile(
    ProfileRef profile, {
    ProfileSection section = ProfileSection.notes,
    String cursor = '',
  }) => _exclusive(() async {
    _requireXhsProfile(profile);
    final key = '${profile.id}:${section.id}';
    if (cursor.isEmpty || _activeProfileKey != key) {
      final uri = _profileUri(profile, section: section);
      await _navigate(uri);
      _activeProfileKey = key;
      _profileItemCount = 0;
    } else {
      await controller.scrollBy(0, 1800);
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    final page = ProfilePage.decode(
      await _waitForJson(
        xhsProfileScript(profile.id, profile.token, section.id),
        attempts: 32,
      ),
    );
    final madeProgress =
        cursor.isEmpty || page.items.length > _profileItemCount;
    _profileItemCount = page.items.length;
    return ProfilePage(
      ref: page.ref,
      name: page.name,
      avatar: page.avatar,
      description: page.description,
      redId: page.redId,
      location: page.location,
      stats: page.stats,
      items: page.items,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore && madeProgress,
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
        var found = await _scriptBool(xhsReplyTargetScript(comment.id));
        for (var attempt = 0; !found && attempt < 10; attempt++) {
          await _loadMoreComments();
          found = await _scriptBool(xhsReplyTargetScript(comment.id));
        }
        if (!found) {
          throw StateError('当前评论区中没有找到回复目标');
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
    _activeListKey = null;
    _activeDetailId = null;
    _activeProfileKey = null;
    final completer = Completer<Uri>();
    _pageFinished = completer;
    await controller.loadRequest(uri);
    await completer.future.timeout(const Duration(seconds: 45));
  }

  Future<void> _desktopizePage() async {
    try {
      await controller.runJavaScript(xhsDesktopPageScript);
    } catch (_) {
      // A redirect may replace the document while the desktop style is being
      // injected. The next onPageFinished callback retries it.
    }
  }

  Future<void> _loadMoreComments() async {
    await controller.runJavaScript(xhsLoadMoreCommentsScript);
    await Future<void>.delayed(const Duration(milliseconds: 900));
  }

  Future<void> _applySearchFilters() async {
    if (_searchFilters.isDefault) return;
    for (final MapEntry<String, String> entry
        in _searchFilters.selections.entries) {
      final defaultValue = entry.key == '排序依据' ? '综合' : '不限';
      if (entry.value == defaultValue) continue;
      await _ensureSearchFilterPanel();
      if (!await _scriptBool(
        xhsSelectSearchFilterScript(entry.key, entry.value),
      )) {
        throw StateError('小红书搜索页不支持「${entry.value}」筛选');
      }
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    await Future<void>.delayed(const Duration(milliseconds: 900));
  }

  Future<void> _ensureSearchFilterPanel() async {
    if (await _scriptBool(
      "document.querySelector('div.filter-panel') !== null",
    )) {
      return;
    }
    if (!await _scriptBool(xhsOpenSearchFiltersScript)) {
      throw StateError('小红书搜索页没有找到筛选入口');
    }
    for (var attempt = 0; attempt < 12; attempt++) {
      if (await _scriptBool(
        "document.querySelector('div.filter-panel') !== null",
      )) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('小红书搜索筛选面板未打开');
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

  Uri _profileUri(
    ProfileRef ref, {
    ProfileSection section = ProfileSection.notes,
  }) {
    final base = ref.url.isNotEmpty
        ? Uri.parse(ref.url)
        : Uri.https(
            'www.xiaohongshu.com',
            '/user/profile/${ref.id}',
            <String, String>{'xsec_token': ref.token, 'xsec_source': 'pc_note'},
          );
    if (section == ProfileSection.notes) return base;
    return base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        'tab': section.id,
        'subTab': 'note',
      },
    );
  }

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

  FeedPage _scrollablePage(FeedPage page) => FeedPage(
    items: page.items,
    nextCursor: page.items.isEmpty ? '' : 'more',
    hasMore: page.items.isNotEmpty,
    notices: page.notices,
  );
}
