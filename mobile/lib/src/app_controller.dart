import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'content_filters.dart';
import 'design_system.dart';
import 'local_settings.dart';
import 'models.dart';
import 'source.dart';
import 'source_diagnostics.dart';
import 'tieba_source.dart';
import 'xhs_web_source.dart';
import 'zhihu_source.dart';

@immutable
class SearchNavigationRequest {
  const SearchNavigationRequest({
    required this.id,
    required this.source,
    required this.query,
  });

  final int id;
  final SourceId source;
  final String query;
}

class MixsocialController extends ChangeNotifier {
  MixsocialController({
    required this.xhs,
    required this.tieba,
    ZhihuSource? zhihu,
    required this.settings,
    this.refreshWaitLimit = const Duration(seconds: 2),
    this.initialWaitLimit = const Duration(seconds: 4),
  }) : zhihu = zhihu ?? ZhihuSource.unavailable();

  final XhsWebSource xhs;
  final TiebaSource tieba;
  final ZhihuSource zhihu;
  final LocalSettings settings;
  final Duration refreshWaitLimit;
  final Duration initialWaitLimit;

  SourceId source = SourceId.all;
  FeedChannel channel = FeedChannel.recommend;
  FeedLayout layout = FeedLayout.masonry;
  List<FeedItem> items = const <FeedItem>[];
  List<String> notices = const <String>[];
  String? error;
  bool loading = false;
  bool loadingMore = false;
  String? paginationError;
  String searchQuery = '';
  FeedDensity density = FeedDensity.standard;
  final ValueNotifier<AppThemePreference> themePreferenceNotifier =
      ValueNotifier<AppThemePreference>(AppThemePreference.system);
  final ValueNotifier<SearchNavigationRequest?> searchNavigationNotifier =
      ValueNotifier<SearchNavigationRequest?>(null);
  Map<SourceId, int> sourceWeights = {};
  bool unreadFirst = false;
  Set<String> _readKeys = {};
  ContentFilters _filters = const ContentFilters();
  List<Author> _blockedAuthors = <Author>[];
  Set<String> _savedKeys = <String>{};
  Set<String> _followingProfiles = <String>{};
  final Map<String, bool> _confirmedFollowing = <String, bool>{};
  final Set<String> _pendingFollows = {};
  final Map<SourceId, int> _followAccountGeneration = {};
  final Map<String, int> _relationshipReadVersions = {};
  final Map<String, bool> _confirmedForums = {};
  Map<SourceId, String> _nextCursors = <SourceId, String>{};
  Set<SourceId> _moreSources = <SourceId>{};
  int _requestVersion = 0;
  int _searchNavigationVersion = 0;
  final Map<String, _FeedSession> _sessions = {};
  String get _filterKey => _sessionFilters.key;
  XhsSearchFilters _sessionFilters = const XhsSearchFilters();
  String? _homeSession;
  String? _searchSession;
  SourceId _homeSource = SourceId.all;
  FeedChannel _homeChannel = FeedChannel.recommend;

  String get sessionKey => jsonEncode([
    source.id,
    channel.id,
    searchQuery,
    searchQuery.isEmpty ? '' : _filterKey,
  ]);

  void _rememberSession() {
    if (items.isEmpty) return;
    final key = sessionKey;
    _sessions.remove(key);
    _sessions[key] = _FeedSession(
      source,
      channel,
      searchQuery,
      layout,
      List.of(items),
      List.of(notices),
      Map.of(_nextCursors),
      Set.of(_moreSources),
      paginationError,
      _sessionFilters,
    );
    while (_sessions.length > 16) {
      _sessions.remove(_sessions.keys.first);
    }
  }

  bool _restoreSession(String key) {
    final saved = _sessions[key];
    if (saved == null) return false;
    _invalidateContent(clearItems: true);
    source = saved.source;
    channel = saved.channel;
    searchQuery = saved.query;
    layout = saved.layout;
    items = prepareItems(saved.items);
    notices = saved.notices;
    _nextCursors = Map.of(saved.cursors);
    _moreSources = Set.of(saved.more);
    paginationError = saved.paginationError;
    if (saved.query.isNotEmpty) {
      _sessionFilters = saved.filters;
      xhs.setSearchFilters(saved.filters);
    }
    notifyListeners();
    return true;
  }

  void enterSearch() {
    _rememberSession();
    _homeSession = sessionKey;
    _homeSource = source;
    _homeChannel = channel;
    if (_searchSession != null && _restoreSession(_searchSession!)) return;
    _invalidateContent(clearItems: true);
    searchQuery = '';
    notifyListeners();
  }

  final Set<SourceId> sourceLoading = {};
  final Map<SourceId, String> sourceErrors = {};

  List<FeedSource> _selectedSources(SourceId id) => switch (id) {
    SourceId.xhs => [xhs],
    SourceId.tieba => [tieba],
    SourceId.zhihu => [zhihu],
    SourceId.all => [tieba, xhs, if (zhihu.enabled) zhihu],
  };

  Future<void> retrySource(SourceId id) async {
    if (loading || sourceLoading.contains(id)) return;
    final version = _requestVersion;
    sourceLoading.add(id);
    sourceErrors.remove(id);
    notifyListeners();
    try {
      final target = _source(id);
      final page =
          await (searchQuery.isEmpty
                  ? target.browse(channel)
                  : target.search(searchQuery))
              .timeout(refreshWaitLimit);
      if (version != _requestVersion) return;
      final seen = items.map((item) => item.key).toSet();
      items = [
        ...items,
        ...prepareItems(page.items.where((item) => seen.add(item.key))),
      ];
      _recordPagination([_SourcePage(id, page)]);
      error = null;
    } catch (failure) {
      if (version == _requestVersion) {
        sourceErrors[id] = _readFailure(failure, refreshWaitLimit);
      }
    } finally {
      if (version == _requestVersion) {
        sourceLoading.remove(id);
        notifyListeners();
      }
    }
  }

  bool get hasMore => _moreSources.isNotEmpty;

  Future<void> accountChanged(SourceId id) async {
    _requestVersion++;
    _followAccountGeneration[id] = (_followAccountGeneration[id] ?? 0) + 1;
    if (id == SourceId.tieba) _confirmedForums.clear();
    _confirmedFollowing.removeWhere((key, _) => key.startsWith('${id.id}:'));
    _followingProfiles.removeWhere((key) => key.startsWith('${id.id}:'));
    _sessions.removeWhere(
      (_, state) => state.source == id || state.source == SourceId.all,
    );
    items = items.where((item) => item.ref.source != id).toList();
    _nextCursors.remove(id);
    _moreSources.remove(id);
    loading = false;
    loadingMore = false;
    notifyListeners();
    await settings.clearAccountState(id);
  }

  Set<String> get blockedForums =>
      Set<String>.unmodifiable(_filters.blockedForums);
  List<Author> get blockedAuthors => List<Author>.unmodifiable(_blockedAuthors);
  Set<String> get blockedKeywords =>
      Set<String>.unmodifiable(_filters.blockedKeywords);
  bool get hideVideos => _filters.hideVideos;
  bool get hideMedia => _filters.hideMedia;
  AppThemePreference get themePreference => themePreferenceNotifier.value;
  XhsSearchFilters get xhsSearchFilters => xhs.searchFilters;

  static Future<MixsocialController> create() async {
    final values = await Future.wait<Object>(<Future<Object>>[
      XhsWebSource.create(),
      TiebaSource.create(),
      ZhihuSource.create(),
      LocalSettings.create(),
    ]);
    final controller = MixsocialController(
      xhs: values[0] as XhsWebSource,
      tieba: values[1] as TiebaSource,
      zhihu: values[2] as ZhihuSource,
      settings: values[3] as LocalSettings,
    );
    // These reads are independent. Restoring them together keeps disk-backed
    // preferences and caches off the critical path as much as possible.
    final restored = await Future.wait<Object>(<Future<Object>>[
      controller.settings.layoutFor(SourceId.all),
      controller.settings.feedDensity(),
      controller.settings.themePreference(),
      controller.settings.blockedForums(),
      controller.settings.blockedKeywords(),
      controller.settings.hideVideos(),
      controller.settings.hideMedia(),
      controller.settings.savedItems(),
      controller.settings.followingProfiles(),
      controller.settings.feedCache(SourceId.all, FeedChannel.recommend),
      controller.settings.blockedAuthors(),
      controller.settings.confirmedFollowing(),
    ]);
    controller.layout = restored[0] as FeedLayout;
    controller.density = restored[1] as FeedDensity;
    controller.themePreferenceNotifier.value =
        restored[2] as AppThemePreference;
    controller._filters = ContentFilters(
      blockedProfiles: (restored[10] as List<Author>)
          .map((author) => author.ref.key)
          .toSet(),
      blockedForums: restored[3] as Set<String>,
      blockedKeywords: restored[4] as Set<String>,
      hideVideos: restored[5] as bool,
      hideMedia: restored[6] as bool,
    );
    controller._savedKeys = (restored[7] as List<FeedItem>)
        .map((FeedItem item) => item.key)
        .toSet();
    controller._followingProfiles = restored[8] as Set<String>;
    controller._blockedAuthors = restored[10] as List<Author>;
    controller._confirmedFollowing.addAll(restored[11] as Map<String, bool>);
    final cached = restored[9] as List<FeedItem>;
    controller.items = controller.prepareItems(cached);
    if (controller.items.isNotEmpty) {
      controller.notices = const <String>['已恢复上次内容，正在后台更新'];
    }
    await controller._loadMixPreferences();
    return controller;
  }

  Future<void> _loadMixPreferences() async {
    sourceWeights = await settings.sourceWeights();
    unreadFirst = await settings.unreadFirst();
    _readKeys = (await settings.historyItems()).map((item) => item.key).toSet();
  }

  Future<void> setSourceWeight(SourceId id, int value) async {
    await settings.setSourceWeight(id, value);
    sourceWeights[id] = value.clamp(1, 3);
    notifyListeners();
  }

  Future<void> setUnreadFirst(bool value) async {
    await settings.setUnreadFirst(value);
    unreadFirst = value;
    _readKeys = (await settings.historyItems()).map((item) => item.key).toSet();
    notifyListeners();
  }

  Future<void> manualRefresh() => refresh(
    clearItems: true,
    restoreCacheOnFailure: false,
    waitLimit: refreshWaitLimit,
  );

  Future<void> refresh({
    bool clearItems = false,
    bool restoreCacheOnFailure = true,
    Duration? waitLimit,
  }) async {
    final requestVersion = ++_requestVersion;
    final selectedSource = source;
    final selectedChannel = channel;
    final query = searchQuery;
    final previousCursors = Map<SourceId, String>.of(_nextCursors);
    final previousMoreSources = Set<SourceId>.of(_moreSources);
    final previousItems = items;
    sourceErrors.clear();
    sourceLoading
      ..clear()
      ..addAll(_selectedSources(selectedSource).map((s) => s.id));
    loading = true;
    loadingMore = false;
    error = null;
    paginationError = null;
    _nextCursors = <SourceId, String>{};
    _moreSources = <SourceId>{};
    if (clearItems) {
      items = const <FeedItem>[];
      notices = const <String>[];
    }
    notifyListeners();
    try {
      final batch = await _loadPages(
        selectedSource: selectedSource,
        selectedChannel: selectedChannel,
        query: query,
        waitLimit: waitLimit ?? initialWaitLimit,
        onPage: (result) {
          if (requestVersion != _requestVersion) return;
          sourceLoading.remove(result.source);
          notifyListeners();
        },
        onFailure: (id, message) {
          if (requestVersion != _requestVersion) return;
          sourceLoading.remove(id);
          sourceErrors[id] = message;
          notifyListeners();
        },
      );
      if (requestVersion != _requestVersion) return;
      final pagesBySource = <SourceId, List<FeedItem>>{
        for (final result in batch.pages) result.source: result.page.items,
        if (!clearItems)
          for (final failedSource in batch.failedSources)
            failedSource: previousItems
                .where((item) => item.ref.source == failedSource)
                .toList(),
      };
      final merged = _roundRobin(
        <SourceId>[SourceId.tieba, SourceId.xhs, SourceId.zhihu]
            .where(pagesBySource.containsKey)
            .map((id) => pagesBySource[id]!)
            .toList(),
      );
      items = prepareItems(merged);
      notices = <String>[
        ...batch.pages.expand((_SourcePage result) => result.page.notices),
      ];
      _recordPagination(batch.pages);
      if (!clearItems) {
        for (final failedSource in batch.failedSources) {
          if (previousMoreSources.contains(failedSource)) {
            _moreSources.add(failedSource);
            final cursor = previousCursors[failedSource];
            if (cursor != null) _nextCursors[failedSource] = cursor;
          }
        }
      }
      if (query.isEmpty && batch.failures.isEmpty) {
        try {
          await settings.saveFeedCache(selectedSource, selectedChannel, merged);
        } catch (_) {
          // A cache write must never turn a successful network refresh into an
          // error screen.
        }
      }
      if (items.isEmpty && notices.isEmpty) {
        notices = const <String>['当前频道没有内容'];
      }
    } catch (failure) {
      if (requestVersion != _requestVersion) return;
      error = failure is _PageLoadFailure
          ? failure.message
          : SourceFailure.from(failure).message;
      if (items.isNotEmpty) {
        _nextCursors = previousCursors;
        _moreSources = previousMoreSources;
        notices = const <String>['网络更新失败，当前仍显示已有内容'];
      } else if (restoreCacheOnFailure && query.isEmpty) {
        final cached = await settings.feedCache(
          selectedSource,
          selectedChannel,
        );
        if (requestVersion != _requestVersion) return;
        if (cached.isNotEmpty) {
          items = prepareItems(cached);
          notices = <String>['网络读取失败，当前显示上次缓存'];
          error = null;
        }
      }
    } finally {
      if (requestVersion == _requestVersion) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (loading || loadingMore || _moreSources.isEmpty) return;
    final requestedSources = _moreSources.difference(sourceLoading);
    if (requestedSources.isEmpty) return;
    final requestVersion = _requestVersion;
    final selectedSource = source;
    final selectedChannel = channel;
    final query = searchQuery;
    final cursors = Map<SourceId, String>.of(_nextCursors);
    loadingMore = true;
    paginationError = null;
    notifyListeners();
    try {
      final batch = await _loadPages(
        selectedSource: selectedSource,
        selectedChannel: selectedChannel,
        query: query,
        cursors: cursors,
        onlySources: requestedSources,
        waitLimit: refreshWaitLimit,
      );
      if (requestVersion != _requestVersion) return;

      final existing = items.map(_itemKey).toSet();
      final additionsBySource = <List<FeedItem>>[];
      final pagesWithAdditions = <_SourcePage>[];
      for (final result in batch.pages) {
        final additions = result.page.items
            .where((FeedItem item) => existing.add(_itemKey(item)))
            .toList();
        additionsBySource.add(additions);
        if (additions.isEmpty && !result.page.hasMore) {
          _moreSources.remove(result.source);
          _nextCursors.remove(result.source);
        } else {
          pagesWithAdditions.add(result);
          if (additions.isEmpty) {
            paginationError = '${result.source.label}暂未返回新内容，请点击重试继续加载';
          }
        }
      }
      items = <FeedItem>[
        ...items,
        ...prepareItems(_roundRobin(additionsBySource)),
      ];
      _recordPagination(pagesWithAdditions);
      notices = <String>{
        ...notices,
        ...batch.pages.expand((_SourcePage result) => result.page.notices),
        ...batch.failures,
      }.toList();
      if (batch.failures.isNotEmpty) {
        paginationError = batch.failures.join('\n');
      }
    } catch (failure) {
      if (requestVersion != _requestVersion) return;
      paginationError = failure is _PageLoadFailure
          ? failure.message
          : SourceFailure.from(failure).message;
    } finally {
      if (requestVersion == _requestVersion) {
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  String _readFailure(Object error, Duration limit) => error is TimeoutException
      ? '读取超时，点按重试（等待上限 ${limit.inMilliseconds / 1000} 秒）'
      : SourceFailure.from(error).message;

  Future<_PageBatch> _loadPages({
    required SourceId selectedSource,
    required FeedChannel selectedChannel,
    required String query,
    Map<SourceId, String> cursors = const <SourceId, String>{},
    Set<SourceId>? onlySources,
    required Duration waitLimit,
    void Function(_SourcePage)? onPage,
    void Function(SourceId, String)? onFailure,
  }) async {
    final sources = _selectedSources(
      selectedSource,
    ).where((item) => onlySources?.contains(item.id) ?? true).toList();
    if (sources.isEmpty) {
      return const _PageBatch(<_SourcePage>[], <String>[], <SourceId>{});
    }

    final batchId = sourceDiagnostics.beginLoad(selectedSource);
    final batchClock = Stopwatch()..start();
    final results = await Future.wait<_PageResult>(
      sources.map((FeedSource item) async {
        final sourceClock = Stopwatch()..start();
        try {
          final cursor = cursors[item.id] ?? '';
          final page =
              await (query.isEmpty
                      ? item.browse(selectedChannel, cursor: cursor)
                      : item.search(query, cursor: cursor))
                  .timeout(waitLimit);
          sourceDiagnostics.recordLoad(
            batchId,
            item.id,
            'ready',
            sourceClock.elapsed,
            itemCount: page.items.length,
          );
          final result = _SourcePage(item.id, page);
          onPage?.call(result);
          return _PageResult(result, null);
        } catch (error) {
          sourceDiagnostics.recordLoad(
            batchId,
            item.id,
            error is TimeoutException ? 'timeout' : 'failed',
            sourceClock.elapsed,
          );
          sourceDiagnostics.record(item.id, '读取内容', error);
          final message = _readFailure(error, waitLimit);
          onFailure?.call(item.id, message);
          return _PageResult(null, '${item.id.label}：$message', item.id);
        }
      }),
    );
    final pages = results
        .where((result) => result.page != null)
        .map((result) => result.page!)
        .toList();
    final failures = results
        .where((result) => result.error != null)
        .map((result) => result.error!)
        .toList();
    sourceDiagnostics.recordLoad(
      batchId,
      selectedSource,
      'complete',
      batchClock.elapsed,
      itemCount: pages.fold(0, (count, page) => count + page.page.items.length),
    );
    if (pages.isEmpty) throw _PageLoadFailure(failures.join('\n'));
    return _PageBatch(
      pages,
      failures,
      results
          .where((result) => result.failedSource != null)
          .map((result) => result.failedSource!)
          .toSet(),
    );
  }

  Future<void> selectSource(
    SourceId value, {
    bool preserveSearch = false,
  }) async {
    if (source == value) return;
    _rememberSession();
    _invalidateContent(clearItems: true);
    source = value;
    if (!preserveSearch) searchQuery = '';
    notifyListeners();
    final selectedLayout = await settings.layoutFor(value);
    if (source != value) return;
    layout = selectedLayout;
    notifyListeners();
    if (preserveSearch && searchQuery.isEmpty) return;
    if (_restoreSession(sessionKey)) return;
    await refresh(clearItems: true);
  }

  Future<void> selectChannel(FeedChannel value) async {
    if (channel == value && searchQuery.isEmpty) return;
    _rememberSession();
    _invalidateContent(clearItems: true);
    channel = value;
    searchQuery = '';
    notifyListeners();
    if (_restoreSession(sessionKey)) return;
    await refresh(clearItems: true);
  }

  Future<void> toggleLayout() async {
    layout = layout == FeedLayout.masonry
        ? FeedLayout.list
        : FeedLayout.masonry;
    await settings.setLayout(source, layout);
    notifyListeners();
  }

  Future<void> search(String value) async {
    final query = value.trim();
    _rememberSession();
    _invalidateContent(clearItems: true);
    searchQuery = query;
    notifyListeners();
    if (query.isNotEmpty && _restoreSession(sessionKey)) return;
    if (query.isNotEmpty) await refresh(clearItems: true);
  }

  void requestSearchNavigation(SourceId source, String value) {
    final query = value.trim().replaceFirst(RegExp(r'^#'), '');
    if (query.isEmpty || source == SourceId.all) return;
    searchNavigationNotifier.value = SearchNavigationRequest(
      id: ++_searchNavigationVersion,
      source: source,
      query: query,
    );
  }

  Future<void> setXhsSearchFilters(XhsSearchFilters value) async {
    if (xhs.searchFilters.key == value.key) return;
    _rememberSession();
    _sessionFilters = value;
    xhs.setSearchFilters(value);
    notifyListeners();
    if (searchQuery.isNotEmpty &&
        (source == SourceId.xhs || source == SourceId.all)) {
      if (_restoreSession(sessionKey)) return;
      await refresh(clearItems: true);
    }
  }

  Future<void> restoreFeed() async {
    _rememberSession();
    if (searchQuery.isNotEmpty) _searchSession = sessionKey;
    if (_homeSession != null && _restoreSession(_homeSession!)) return;
    if (searchQuery.isEmpty && items.isNotEmpty) return;
    _invalidateContent(clearItems: true);
    searchQuery = '';
    source = _homeSource;
    channel = _homeChannel;
    notifyListeners();
    await refresh(clearItems: true);
  }

  Future<FeedDetail> detail(ContentRef ref) => _source(ref.source).detail(ref);

  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) {
    final target = _source(ref.source);
    if (target is ThreadPageReader) {
      return (target as ThreadPageReader).detailPage(
        ref,
        cursor: cursor,
        reverse: reverse,
        onlyOriginalPoster: onlyOriginalPoster,
      );
    }
    return target.detail(ref);
  }

  Future<FeedPage> forum(
    String forum, {
    String cursor = '',
    int sortType = 0,
    String query = '',
  }) => query.trim().isEmpty
      ? tieba.forum(forum, cursor: cursor, sortType: sortType)
      : tieba.searchForum(forum, query, cursor: cursor);

  Future<List<String>> followingForums() => tieba.followingForums();

  bool? confirmedForumFollowing(String forum) =>
      _confirmedForums[normalizeForumName(forum)];

  Future<bool> forumFollowing(String forum) async {
    final name = normalizeForumName(forum);
    if (name.isEmpty) throw ArgumentError('贴吧名称不能为空');
    final key = 'forum:$name';
    if (_pendingFollows.contains(key)) {
      final known = _confirmedForums[name];
      if (known != null) return known;
      throw StateError('正在更新关注状态，请稍候');
    }
    final version = (_relationshipReadVersions[key] ?? 0) + 1;
    _relationshipReadVersions[key] = version;
    final account = _followAccountGeneration[SourceId.tieba] ?? 0;
    final value = await tieba.forumFollowing(name);
    if (account != (_followAccountGeneration[SourceId.tieba] ?? 0)) {
      throw StateError('账号已切换，请重新读取关注状态');
    }
    if (version == _relationshipReadVersions[key] &&
        !_pendingFollows.contains(key)) {
      _confirmedForums[name] = value;
      notifyListeners();
    }
    return _confirmedForums[name] ?? value;
  }

  Future<void> followForum(String forum, bool value) async {
    final name = normalizeForumName(forum);
    if (name.isEmpty) throw ArgumentError('贴吧名称不能为空');
    final key = 'forum:$name';
    if (!_pendingFollows.add(key)) throw StateError('正在更新关注状态，请稍候');
    _relationshipReadVersions[key] = (_relationshipReadVersions[key] ?? 0) + 1;
    final account = _followAccountGeneration[SourceId.tieba] ?? 0;
    try {
      await tieba.followForum(name, value);
      if (account != (_followAccountGeneration[SourceId.tieba] ?? 0)) {
        throw StateError('账号已切换，请重新读取关注状态');
      }
      _confirmedForums[name] = value;
      notifyListeners();
    } finally {
      _pendingFollows.remove(key);
    }
  }

  Future<bool> readFollowing(
    ProfileRef profile, {
    bool fallback = false,
  }) async {
    if (!profile.isIdentifiable) throw ArgumentError('无法识别该作者');
    final target = _source(profile.source);
    if (target is! RelationshipStateReader ||
        _pendingFollows.contains(profile.key)) {
      return isFollowing(profile, fallback: fallback);
    }
    final version = (_relationshipReadVersions[profile.key] ?? 0) + 1;
    _relationshipReadVersions[profile.key] = version;
    final account = _followAccountGeneration[profile.source] ?? 0;
    final value = await (target as RelationshipStateReader).following(profile);
    if (account != (_followAccountGeneration[profile.source] ?? 0)) {
      throw StateError('账号已切换，请重新读取关注状态');
    }
    if (version == _relationshipReadVersions[profile.key] &&
        !_pendingFollows.contains(profile.key)) {
      _confirmedFollowing[profile.key] = value;
      value
          ? _followingProfiles.add(profile.key)
          : _followingProfiles.remove(profile.key);
      notifyListeners();
    }
    return isFollowing(profile, fallback: value);
  }

  Future<ProfilePage> profile(
    ProfileRef profile, {
    ProfileSection section = ProfileSection.notes,
    String cursor = '',
  }) {
    final target = _source(profile.source);
    if (target is! ProfileReader) {
      throw StateError('${profile.source.label}暂不支持作者主页');
    }
    return (target as ProfileReader).profile(
      profile,
      section: section,
      cursor: cursor,
    );
  }

  bool supportsProfile(SourceId id) =>
      id != SourceId.all && _source(id) is ProfileReader;

  Future<FeedCommentPage> floorReplies(ContentRef floor, {String cursor = ''}) {
    final target = _source(floor.source);
    if (target is! FloorReplyReader) {
      throw StateError('${floor.source.label}暂不支持读取全部楼中楼');
    }
    return (target as FloorReplyReader).floorReplies(floor, cursor: cursor);
  }

  bool supportsFloorReplies(SourceId source) =>
      source != SourceId.all && _source(source) is FloorReplyReader;

  bool supports(SourceId id, SourceCapability capability) =>
      id != SourceId.all && _source(id).capabilities.contains(capability);

  Future<String?> follow(ProfileRef profile, bool value) async {
    if (!profile.isIdentifiable) throw ArgumentError('无法识别该作者');
    if (!_pendingFollows.add(profile.key)) {
      throw StateError('正在更新关注状态，请稍候');
    }
    _relationshipReadVersions[profile.key] =
        (_relationshipReadVersions[profile.key] ?? 0) + 1;
    final accountGeneration = _followAccountGeneration[profile.source] ?? 0;
    try {
      final target = _source(profile.source);
      if (target is! RelationshipInteractor) {
        throw StateError('${profile.source.label}暂不支持关注用户');
      }
      await (target as RelationshipInteractor).follow(profile, value);
      if ((_followAccountGeneration[profile.source] ?? 0) !=
          accountGeneration) {
        throw StateError('账号已切换，请在原账号确认关注状态');
      }
      // A platform-confirmed cancellation must override stale author snapshots,
      // including snapshots restored from the local feed cache.
      _confirmedFollowing[profile.key] = value;
      value
          ? _followingProfiles.add(profile.key)
          : _followingProfiles.remove(profile.key);
      items = items
          .map(
            (FeedItem item) => item.author.ref.key == profile.key
                ? item.copyWith(author: item.author.copyWith(following: value))
                : item,
          )
          .toList();
      notifyListeners();
      try {
        await settings.setFollowing(profile, value);
      } catch (failure) {
        return '${profile.source.label}${value ? '已关注' : '已取消关注'}，但本地记录保存失败：${safeLocalMessage(failure)}';
      }
      return null;
    } finally {
      _pendingFollows.remove(profile.key);
    }
  }

  bool isFollowing(
    ProfileRef profile, {
    bool fallback = false,
    bool? observed,
  }) =>
      _confirmedFollowing[profile.key] ??
      observed ??
      (_followingProfiles.contains(profile.key) || fallback);

  bool isForumBlocked(String forum) =>
      _filters.blockedForums.contains(normalizeForumName(forum));

  bool isAuthorBlocked(ProfileRef profile) =>
      _filters.blockedProfiles.contains(profile.key);

  bool isItemBlocked(FeedItem item) => _filters.blocks(item);

  Future<void> setAuthorBlocked(Author author, bool value) async {
    await settings.setAuthorBlocked(author, value);
    _blockedAuthors = await settings.blockedAuthors();
    _filters = _filters.copyWith(
      blockedProfiles: _blockedAuthors.map((author) => author.ref.key).toSet(),
    );
    items = prepareItems(items);
    notifyListeners();
    if (!value) await refresh(clearItems: true);
  }

  Future<void> setForumBlocked(String forum, bool value) async {
    final normalized = normalizeForumName(forum);
    if (normalized.isEmpty) return;
    await settings.setForumBlocked(normalized, value);
    final forums = Set<String>.of(_filters.blockedForums);
    value ? forums.add(normalized) : forums.remove(normalized);
    _filters = _filters.copyWith(blockedForums: forums);
    items = prepareItems(items);
    notifyListeners();
    if (!value) await refresh(clearItems: true);
  }

  Future<void> setKeywordBlocked(String keyword, bool value) async {
    final normalized = normalizeKeyword(keyword);
    if (normalized.isEmpty) return;
    await settings.setKeywordBlocked(normalized, value);
    final keywords = Set<String>.of(_filters.blockedKeywords);
    value ? keywords.add(normalized) : keywords.remove(normalized);
    _filters = _filters.copyWith(blockedKeywords: keywords);
    items = prepareItems(items);
    notifyListeners();
    if (!value) await refresh(clearItems: true);
  }

  Future<void> setHideVideos(bool value) async {
    await settings.setHideVideos(value);
    _filters = _filters.copyWith(hideVideos: value);
    if (value) items = prepareItems(items);
    notifyListeners();
    if (!value) await refresh(clearItems: true);
  }

  Future<void> setHideMedia(bool value) async {
    await settings.setHideMedia(value);
    _filters = _filters.copyWith(hideMedia: value);
    if (value) items = prepareItems(items);
    notifyListeners();
    if (!value) await refresh(clearItems: true);
  }

  Future<void> setDensity(FeedDensity value) async {
    if (density == value) return;
    density = value;
    await settings.setFeedDensity(value);
    notifyListeners();
  }

  Future<void> setThemePreference(AppThemePreference value) async {
    if (themePreference == value) return;
    themePreferenceNotifier.value = value;
    notifyListeners();
    await settings.setThemePreference(value);
  }

  /// Reloads preferences written by a device migration without a network fetch.
  Future<void> reloadLocalPreferences() async {
    await _loadMixPreferences();
    layout = await settings.layoutFor(source);
    density = await settings.feedDensity();
    themePreferenceNotifier.value = await settings.themePreference();
    _blockedAuthors = await settings.blockedAuthors();
    _filters = ContentFilters(
      blockedProfiles: _blockedAuthors.map((author) => author.ref.key).toSet(),
      blockedForums: await settings.blockedForums(),
      blockedKeywords: await settings.blockedKeywords(),
      hideVideos: await settings.hideVideos(),
      hideMedia: await settings.hideMedia(),
    );
    _savedKeys = (await settings.savedItems()).map((item) => item.key).toSet();
    _followingProfiles = await settings.followingProfiles();
    _confirmedFollowing
      ..clear()
      ..addAll(await settings.confirmedFollowing());
    items = prepareItems(items);
    notifyListeners();
  }

  Future<void> like(ContentRef ref, bool value) async {
    await _contentAction(
      ref,
      (ContentInteractor source) => source.like(ref, value),
    );
    _updateItem(
      ref,
      (FeedItem item) => item.copyWith(
        liked: value,
        stats: item.stats.copyWith(
          likes: _changedCount(item.stats.likes, item.liked, value),
        ),
      ),
    );
  }

  Future<String?> favorite(FeedItem item, bool value) async {
    final target = _source(item.ref.source);
    final usesPlatform =
        target is ContentInteractor &&
        target.capabilities.contains(SourceCapability.favorite);
    if (usesPlatform) {
      await (target as ContentInteractor).favorite(item.ref, value);
    }
    String? warning;
    try {
      await settings.setSaved(item, value);
      value ? _savedKeys.add(item.key) : _savedKeys.remove(item.key);
    } catch (failure) {
      if (!usesPlatform) rethrow;
      warning = value
          ? '小红书已收藏，但本地副本保存失败：${safeLocalMessage(failure)}'
          : '小红书已取消收藏，但本地副本移除失败：${safeLocalMessage(failure)}';
    }
    _updateItem(
      item.ref,
      (FeedItem current) => current.copyWith(
        favorited: usesPlatform ? value : current.favorited,
        localSaved: _savedKeys.contains(item.key),
        stats: current.stats.copyWith(
          favorites: usesPlatform
              ? _changedCount(current.stats.favorites, current.favorited, value)
              : current.stats.favorites,
        ),
      ),
    );
    return warning;
  }

  bool isSaved(FeedItem item) => _savedKeys.contains(item.key);

  Future<void> recordHistory(FeedItem item) async {
    await settings.addHistory(item);
    _readKeys.add(item.key);
  }

  Future<List<FeedItem>> historyItems() async =>
      prepareItems(await settings.historyItems());

  Future<List<FeedItem>> savedItems() async =>
      prepareItems(await settings.savedItems());

  Future<List<FeedItem>> readLaterItems() async =>
      prepareItems(await settings.readLaterItems());

  Future<bool> isReadLater(FeedItem item) => settings.isReadLater(item.key);

  Future<void> setReadLater(FeedItem item, bool value) async {
    await settings.setReadLater(item, value);
    notifyListeners();
  }

  Future<void> setLocalSaved(FeedItem item, bool value) async {
    await settings.setSaved(item, value);
    value ? _savedKeys.add(item.key) : _savedKeys.remove(item.key);
    items = items
        .map(
          (current) => current.key == item.key
              ? current.copyWith(localSaved: value)
              : current,
        )
        .toList();
    notifyListeners();
  }

  Future<void> clearHistory() => settings.clearHistory();

  Future<List<String>> recentForums() => settings.recentForums();

  Future<void> recordForumVisit(String forum) => settings.addRecentForum(forum);

  Future<void> comment(ContentRef ref, String body) async {
    await _contentAction(
      ref,
      (ContentInteractor source) => source.comment(ref, body),
    );
    _updateItem(
      ref,
      (FeedItem item) => item.copyWith(
        stats: item.stats.copyWith(comments: item.stats.comments + 1),
      ),
    );
  }

  Future<void> reply(ContentRef ref, ContentRef comment, String body) async {
    await _contentAction(
      ref,
      (ContentInteractor source) => source.reply(ref, comment, body),
    );
    _updateItem(
      ref,
      (FeedItem item) => item.copyWith(
        stats: item.stats.copyWith(comments: item.stats.comments + 1),
      ),
    );
  }

  Future<void> _contentAction(
    ContentRef ref,
    Future<void> Function(ContentInteractor) action,
  ) async {
    final target = _source(ref.source);
    if (target is! ContentInteractor) {
      throw StateError('${ref.source.label}暂不支持此操作');
    }
    await action(target as ContentInteractor);
  }

  Future<void> commentLike(
    ContentRef ref,
    ContentRef comment,
    bool value,
  ) async {
    if (comment.source != ref.source || comment.id.isEmpty) {
      throw ArgumentError('评论目标与内容来源不一致或为空');
    }
    final target = _source(ref.source);
    if (target is! CommentInteractor ||
        !target.capabilities.contains(SourceCapability.commentLike)) {
      throw StateError('${ref.source.label}暂不支持评论点赞');
    }
    await (target as CommentInteractor).commentLike(ref, comment, value);
  }

  FeedSource _source(SourceId id) => switch (id) {
    SourceId.xhs => xhs,
    SourceId.tieba => tieba,
    SourceId.zhihu => zhihu,
    SourceId.all => throw ArgumentError('全部不是具体数据源'),
  };

  void _updateItem(ContentRef ref, FeedItem Function(FeedItem) update) {
    var changed = false;
    items = items.map((FeedItem item) {
      if (item.ref.key != ref.key) {
        return item;
      }
      changed = true;
      return update(item);
    }).toList();
    if (changed) notifyListeners();
  }

  int _changedCount(int current, bool oldValue, bool newValue) {
    if (oldValue == newValue) return current;
    return (current + (newValue ? 1 : -1)).clamp(0, 1 << 31);
  }

  List<FeedItem> prepareItems(Iterable<FeedItem> values) => _filters
      .apply(values)
      .map((item) => item.copyWith(localSaved: _savedKeys.contains(item.key)))
      .toList();

  List<FeedComment> prepareComments(Iterable<FeedComment> values) => values
      .where(
        (FeedComment item) =>
            !_filters.blocksAuthor(item.author) &&
            !_filters.blocksText(item.body),
      )
      .map(
        (FeedComment item) => item.copyWith(
          media: hideMedia ? const <MediaItem>[] : item.media,
          replies: prepareComments(item.replies),
        ),
      )
      .toList();

  void _recordPagination(Iterable<_SourcePage> pages) {
    for (final result in pages) {
      if (!result.page.hasMore) {
        _moreSources.remove(result.source);
        _nextCursors.remove(result.source);
        continue;
      }
      _moreSources.add(result.source);
      _nextCursors[result.source] = result.page.nextCursor.isNotEmpty
          ? result.page.nextCursor
          : 'more';
    }
  }

  void _invalidateContent({required bool clearItems}) {
    _requestVersion++;
    sourceLoading.clear();
    sourceErrors.clear();
    loading = false;
    loadingMore = false;
    error = null;
    paginationError = null;
    _nextCursors = <SourceId, String>{};
    _moreSources = <SourceId>{};
    notices = const <String>[];
    if (clearItems) items = const <FeedItem>[];
  }

  String _itemKey(FeedItem item) => item.key;

  List<FeedItem> _roundRobin(List<List<FeedItem>> groups) {
    final result = <FeedItem>[];
    final positions = List.filled(groups.length, 0);
    while (true) {
      var added = false;
      for (var index = 0; index < groups.length; index++) {
        final group = groups[index];
        if (group.isEmpty) continue;
        final weight = sourceWeights[group.first.ref.source] ?? 1;
        for (
          var count = 0;
          count < weight && positions[index] < group.length;
          count++
        ) {
          result.add(group[positions[index]++]);
          added = true;
        }
      }
      if (!added) break;
    }
    return unreadFirst
        ? [
            ...result.where((item) => !_readKeys.contains(item.key)),
            ...result.where((item) => _readKeys.contains(item.key)),
          ]
        : result;
  }
}

class _FeedSession {
  const _FeedSession(
    this.source,
    this.channel,
    this.query,
    this.layout,
    this.items,
    this.notices,
    this.cursors,
    this.more,
    this.paginationError,
    this.filters,
  );
  final XhsSearchFilters filters;
  final SourceId source;
  final FeedChannel channel;
  final String query;
  final FeedLayout layout;
  final List<FeedItem> items;
  final List<String> notices;
  final Map<SourceId, String> cursors;
  final Set<SourceId> more;
  final String? paginationError;
}

class _PageResult {
  const _PageResult(this.page, this.error, [this.failedSource]);
  final _SourcePage? page;
  final String? error;
  final SourceId? failedSource;
}

class _SourcePage {
  const _SourcePage(this.source, this.page);
  final SourceId source;
  final FeedPage page;
}

class _PageBatch {
  const _PageBatch(this.pages, this.failures, this.failedSources);
  final List<_SourcePage> pages;
  final List<String> failures;
  final Set<SourceId> failedSources;
}

class _PageLoadFailure {
  const _PageLoadFailure(this.message);
  final String message;
}
