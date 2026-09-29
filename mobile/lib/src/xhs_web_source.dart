import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'models.dart';
import 'source.dart';
import 'xhs_account_scripts.dart';
import 'xhs_comment_interaction_scripts.dart';
import 'xhs_interaction_scripts.dart';
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
        CommentInteractor,
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
    SourceCapability.commentLike,
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

  Future<Author> currentProfile() => _exclusive(() async {
    // Refresh the website's own account state; a persisted session cookie alone
    // is not enough to identify an authenticated user.
    await _navigate(Uri.parse(_exploreUrl));
    try {
      final value = await _waitForJson(xhsCurrentProfileScript, attempts: 24);
      return Author.fromJson(mapOf(jsonDecode(value)), SourceId.xhs);
    } on TimeoutException {
      throw StateError('无法确认当前小红书账号，请打开登录页重新登录或完成验证');
    }
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

  /// Returns cookies only for the Xiaohongshu origin. Callers must protect the
  /// result as account credentials and never log it or place it directly in QR.
  Future<List<Map<String, String>>> exportCookiesForTransfer() async {
    final cookies = await _cookieManager.getCookies(
      domain: Uri.parse('https://www.xiaohongshu.com/'),
    );
    final seen = <String>{};
    return <Map<String, String>>[
      for (final cookie in cookies)
        if (cookie.name.trim().isNotEmpty &&
            cookie.value.isNotEmpty &&
            seen.add(cookie.name.trim()))
          <String, String>{'name': cookie.name.trim(), 'value': cookie.value},
    ];
  }

  Future<void> importCookiesFromTransfer(
    Iterable<Map<String, String>> cookies,
  ) async {
    for (final cookie in cookies) {
      final name = cookie['name'] ?? '';
      final value = cookie['value'] ?? '';
      if (!RegExp(r'^[!#$%&\x27*+.^_`|~0-9A-Za-z-]{1,256}$').hasMatch(name) ||
          value.isEmpty ||
          value.length > 16384 ||
          value.contains(RegExp(r'[\r\n]'))) {
        throw const FormatException('小红书 Cookie 无效');
      }
      await _cookieManager.setCookie(
        WebViewCookie(
          name: name,
          value: value,
          domain: 'www.xiaohongshu.com',
          path: '/',
        ),
      );
    }
    _activeListKey = null;
    _activeDetailId = null;
    _activeProfileKey = null;
  }

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
    var detail = FeedDetail.decode(
      await _waitForJson(xhsDetailScript(ref.id, ref.token), attempts: 40),
    );
    if (cursor.isEmpty &&
        detail.comments.isEmpty &&
        detail.item.stats.comments > 0) {
      await _loadMoreComments();
      for (
        var attempt = 0;
        detail.comments.isEmpty && attempt < 16;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        detail = FeedDetail.decode(
          await _waitForJson(xhsDetailScript(ref.id, ref.token), attempts: 4),
        );
      }
    }
    for (
      var attempt = 0;
      cursor.isNotEmpty &&
          detail.hasMore &&
          detail.comments.length <= _detailCommentCount &&
          attempt < 16;
      attempt++
    ) {
      if (attempt == 7) {
        await _loadMoreComments();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      detail = FeedDetail.decode(
        await _waitForJson(xhsDetailScript(ref.id, ref.token), attempts: 4),
      );
    }
    if (cursor.isNotEmpty &&
        detail.hasMore &&
        detail.comments.length <= _detailCommentCount) {
      throw StateError('小红书评论暂未加载出下一页，请重试');
    }
    _detailCommentCount = detail.comments.length;
    return FeedDetail(
      item: detail.item,
      body: detail.body,
      comments: detail.comments,
      nextCursor: detail.nextCursor,
      hasMore: detail.hasMore,
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
      await _waitForJson(
        xhsDetailScript(floor.parentId, floor.token),
        attempts: 40,
      );
    }
    final script = xhsFloorRepliesScript(floor.parentId, floor.id);
    var raw = await _scriptString(script);
    // Another screen may have reused the WebView. Restore the requested parent
    // by paging through root comments instead of polling a missing SSR entry.
    for (var attempt = 0; raw.isEmpty && attempt < 16; attempt++) {
      await _loadMoreComments();
      raw = await _scriptString(script);
      if (raw.isEmpty && attempt >= 2) {
        final detail = FeedDetail.decode(
          await _waitForJson(
            xhsDetailScript(floor.parentId, floor.token),
            attempts: 4,
          ),
        );
        if (!detail.hasMore) break;
      }
    }
    if (raw.isEmpty) throw StateError('当前小红书页面没有加载到这条评论，请返回详情刷新后重试');
    var page = FeedCommentPage.decode(raw, source: SourceId.xhs);
    var previousCount = int.tryParse(cursor) ?? 0;
    if (cursor.startsWith('{')) {
      final decoded = jsonDecode(cursor);
      if (decoded is Map && decoded['count'] is num) {
        previousCount = (decoded['count'] as num).toInt();
      }
    }
    // Opening a floor expands its first page immediately. Later requests also
    // restore previously expanded pages after the shared WebView navigates.
    for (var round = 0; page.hasMore && round < 12; round++) {
      final before = page.comments.length;
      final beforeCursor = page.nextCursor;
      var clicked = await _scriptBool(xhsLoadMoreFloorRepliesScript(floor.id));
      if (!clicked) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        clicked = await _scriptBool(xhsLoadMoreFloorRepliesScript(floor.id));
      }
      if (!clicked) {
        if (cursor.isEmpty && page.comments.isNotEmpty) return page;
        throw StateError('小红书尚未显示展开回复按钮，请重试');
      }
      for (var attempt = 0; attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        raw = await _scriptString(script);
        if (raw.isEmpty) continue;
        page = FeedCommentPage.decode(raw, source: SourceId.xhs);
        if (page.comments.length > before ||
            page.nextCursor != beforeCursor ||
            !page.hasMore) {
          break;
        }
      }
      if (page.comments.length <= before &&
          page.nextCursor == beforeCursor &&
          page.hasMore) {
        if (cursor.isEmpty && page.comments.isNotEmpty) return page;
        throw StateError('小红书回复暂未加载出下一页，请重试');
      }
      if (cursor.isEmpty || page.comments.length > previousCount) return page;
    }
    if (cursor.isNotEmpty &&
        page.hasMore &&
        page.comments.length <= previousCount) {
      throw StateError('小红书正在恢复已展开的回复，请继续重试');
    }
    return page;
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
    final following = await _scriptString(xhsFollowStateScript(profile.id));
    return ProfilePage(
      ref: page.ref,
      name: page.name,
      avatar: page.avatar,
      avatarUrls: page.avatarUrls,
      description: page.description,
      redId: page.redId,
      location: page.location,
      stats: page.stats,
      items: page.items,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore && madeProgress,
      following: following == 'true'
          ? true
          : following == 'false'
          ? false
          : null,
    );
  });

  @override
  Future<void> like(ContentRef ref, bool value) => _toggleContent(
    ref,
    field: 'liked',
    action: 'like',
    value: value,
    label: value ? '点赞' : '取消点赞',
  );

  @override
  Future<void> favorite(ContentRef ref, bool value) => _toggleContent(
    ref,
    field: 'collected',
    action: 'favorite',
    value: value,
    label: value ? '收藏' : '取消收藏',
  );

  @override
  Future<void> comment(ContentRef ref, String body) => _exclusive(() async {
    _requireXhs(ref);
    final content = body.trim();
    if (content.isEmpty) throw ArgumentError('评论不能为空');
    await _navigate(_contentUri(ref));
    await _submitComment(ref, content);
  });

  @override
  Future<void> reply(ContentRef ref, ContentRef comment, String body) =>
      _exclusive(() async {
        _requireXhs(ref);
        _requireXhs(comment);
        if (comment.id.isEmpty) throw ArgumentError('回复目标不能为空');
        final content = body.trim();
        if (content.isEmpty) throw ArgumentError('回复不能为空');
        await _navigate(_contentUri(ref));
        var found = await _scriptBool(xhsSelectReplyTargetScript(comment.id));
        for (var attempt = 0; !found && attempt < 10; attempt++) {
          await _loadMoreComments();
          if (comment.parentId.isNotEmpty && comment.parentId != ref.id) {
            await controller.runJavaScript(
              xhsLoadMoreFloorRepliesScript(comment.parentId),
            );
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
          found = await _scriptBool(xhsSelectReplyTargetScript(comment.id));
        }
        if (!found) {
          throw StateError('当前评论区中没有找到回复目标');
        }
        await _submitComment(ref, content, targetId: comment.id);
      });

  @override
  Future<void> commentLike(ContentRef ref, ContentRef comment, bool value) =>
      _exclusive(() async {
        _requireXhs(ref);
        _requireXhs(comment);
        if (comment.id.isEmpty) throw ArgumentError('点赞评论目标不能为空');
        await _navigate(_contentUri(ref));
        var current = '';
        // Only read/expand while locating. A missing state must not become an
        // assumed false, and a retry here must never resubmit a write.
        for (var attempt = 0; attempt < 12; attempt++) {
          current = await _scriptString(
            xhsCommentLikeStateScript(ref.id, comment.id),
          );
          if (current == 'true' || current == 'false') break;
          await _loadMoreComments();
          if (comment.parentId.isNotEmpty && comment.parentId != ref.id) {
            await controller.runJavaScript(
              xhsLoadMoreFloorRepliesScript(comment.parentId),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
        if (current != 'true' && current != 'false') {
          throw StateError('未找到这条评论的可用点赞状态，请刷新评论或在网页检查登录');
        }
        if (current == value.toString()) return;
        await _performObservedInteraction(
          ref,
          action: 'commentLike',
          targetId: comment.id,
          value: value,
          trigger: xhsClickCommentLikeScript(comment.id),
          label: value ? '点赞评论' : '取消评论点赞',
        );
      });

  @override
  Future<void> follow(ProfileRef profile, bool value) => _exclusive(() async {
    _requireXhsProfile(profile);
    await _navigate(_profileUri(profile));
    var current = '';
    for (var attempt = 0; attempt < 32; attempt++) {
      current = await _scriptString(xhsFollowStateScript(profile.id));
      if (current == 'true' || current == 'false') break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (current != 'true' && current != 'false') {
      throw StateError('小红书关注状态尚未加载，请在网页检查登录或验证状态');
    }
    if (current == value.toString()) return;
    await _performObservedInteraction(
      null,
      action: 'follow',
      profileId: profile.id,
      value: value,
      trigger: xhsClickFollowScript(value, profile.id),
      confirmationTrigger: value ? null : xhsConfirmUnfollowScript,
      label: value ? '关注' : '取消关注',
    );
  });

  Future<void> _toggleContent(
    ContentRef ref, {
    required String field,
    required String action,
    required bool value,
    required String label,
  }) => _exclusive(() async {
    _requireXhs(ref);
    await _navigate(_contentUri(ref));
    var current = '';
    for (var attempt = 0; attempt < 32; attempt++) {
      current = await _scriptString(
        xhsCurrentInteractionStateScript(ref.id, field),
      );
      if (current == 'true' || current == 'false') break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (current != 'true' && current != 'false') {
      throw StateError('小红书互动状态尚未加载，请在网页检查登录或验证状态');
    }
    if (current == value.toString()) return;
    await _performObservedInteraction(
      ref,
      action: action,
      value: value,
      trigger: xhsClickInteractionScript(action),
      label: label,
    );
  });

  Future<void> _submitComment(
    ContentRef ref,
    String content, {
    String targetId = '',
  }) async {
    final label = targetId.isEmpty ? '评论' : '回复';
    await _waitForBool(xhsFillCommentScript(content), label: '填写$label输入框');
    await _waitForBool(
      xhsSubmitCommentInteractionScript(submit: false),
      label: '等待$label按钮可用',
    );
    await _performObservedInteraction(
      ref,
      action: 'comment',
      content: content,
      targetId: targetId,
      trigger: xhsSubmitCommentInteractionScript(),
      label: label,
    );
  }

  Future<void> _performObservedInteraction(
    ContentRef? ref, {
    required String action,
    required String trigger,
    required String label,
    bool value = false,
    String content = '',
    String targetId = '',
    String profileId = '',
    String? confirmationTrigger,
  }) async {
    final operationId = '${DateTime.now().microsecondsSinceEpoch}';
    await controller.runJavaScript(xhsInstallInteractionObserverScript);
    if (!await _scriptBool(
      xhsBeginInteractionScript(
        operationId: operationId,
        noteId: ref?.id ?? '',
        action: action,
        value: value,
        content: content,
        targetId: targetId,
        profileId: profileId,
      ),
    )) {
      throw StateError('小红书仍有互动等待确认，请刷新检查结果');
    }
    try {
      // Only the readiness checks above may repeat. Never retry this click or
      // switch transports after submission: the server may have accepted it.
      if (!await _scriptBool(trigger)) {
        throw StateError('小红书网页没有找到可用的$label按钮');
      }
      var confirmationClicked = false;
      for (var attempt = 0; attempt < 60; attempt++) {
        final result =
            jsonDecode(
                  await _scriptString(xhsInteractionResultScript(operationId)),
                )
                as Map<String, dynamic>;
        if (result['status'] == 'success') return;
        if (result['status'] == 'error' || result['status'] == 'unknown') {
          throw StateError('$label：${result['message']}');
        }
        // Some website versions unfollow immediately, others open a dialog.
        // Never click a confirmation after a request has already been sent.
        if (confirmationTrigger != null &&
            !confirmationClicked &&
            result['sent'] != true) {
          confirmationClicked = await _scriptBool(confirmationTrigger);
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      throw StateError('$label结果尚未确认，请刷新检查后再操作，避免重复提交');
    } finally {
      try {
        await controller.runJavaScript(xhsCancelInteractionScript(operationId));
      } catch (_) {
        // A navigation can destroy the observer while waiting for a response.
      }
    }
  }

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
