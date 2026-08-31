import 'package:flutter/foundation.dart';

import 'content_filters.dart';
import 'design_system.dart';
import 'local_settings.dart';
import 'models.dart';
import 'source.dart';
import 'tieba_source.dart';
import 'xhs_web_source.dart';

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
  MixsocialController._({
    required this.xhs,
    required this.tieba,
    required this.settings,
  });

  final XhsWebSource xhs;
  final TiebaSource tieba;
  final LocalSettings settings;

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
  ContentFilters _filters = const ContentFilters();
  Set<String> _savedKeys = <String>{};
  Set<String> _followingProfiles = <String>{};
  Map<SourceId, String> _nextCursors = <SourceId, String>{};
  Set<SourceId> _moreSources = <SourceId>{};
  int _requestVersion = 0;
  int _searchNavigationVersion = 0;

  bool get hasMore => _moreSources.isNotEmpty;
  Set<String> get blockedForums =>
      Set<String>.unmodifiable(_filters.blockedForums);
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
      LocalSettings.create(),
    ]);
    final controller = MixsocialController._(
      xhs: values[0] as XhsWebSource,
      tieba: values[1] as TiebaSource,
      settings: values[2] as LocalSettings,
    );
    controller.layout = await controller.settings.layoutFor(SourceId.all);
    controller.density = await controller.settings.feedDensity();
    controller.themePreferenceNotifier.value = await controller.settings
        .themePreference();
    controller._filters = ContentFilters(
      blockedForums: await controller.settings.blockedForums(),
      blockedKeywords: await controller.settings.blockedKeywords(),
      hideVideos: await controller.settings.hideVideos(),
      hideMedia: await controller.settings.hideMedia(),
    );
    controller._savedKeys = (await controller.settings.savedItems())
        .map((FeedItem item) => item.key)
        .toSet();
    controller._followingProfiles = await controller.settings
        .followingProfiles();
    final cached = await controller.settings.feedCache(
      SourceId.all,
      FeedChannel.recommend,
    );
    controller.items = controller.prepareItems(cached);
    if (controller.items.isNotEmpty) {
      controller.notices = const <String>['已恢复上次内容，正在后台更新'];
    }
    return controller;
  }

  Future<void> refresh({bool clearItems = false}) async {
    final requestVersion = ++_requestVersion;
    final selectedSource = source;
    final selectedChannel = channel;
    final query = searchQuery;
    final previousCursors = Map<SourceId, String>.of(_nextCursors);
    final previousMoreSources = Set<SourceId>.of(_moreSources);
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
      );
      if (requestVersion != _requestVersion) return;
      final merged = _roundRobin(
        batch.pages.map((_SourcePage result) => result.page.items).toList(),
      );
      items = prepareItems(merged);
      notices = <String>[
        ...batch.pages.expand((_SourcePage result) => result.page.notices),
        ...batch.failures,
      ];
      _recordPagination(batch.pages);
      if (query.isEmpty) {
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
      error = failure.toString();
      if (items.isNotEmpty) {
        _nextCursors = previousCursors;
        _moreSources = previousMoreSources;
        notices = const <String>['网络更新失败，当前仍显示已有内容'];
      } else if (query.isEmpty) {
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
    final requestVersion = ++_requestVersion;
    final selectedSource = source;
    final selectedChannel = channel;
    final query = searchQuery;
    final requestedSources = Set<SourceId>.of(_moreSources);
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
        if (additions.isEmpty) {
          _moreSources.remove(result.source);
          _nextCursors.remove(result.source);
        } else {
          pagesWithAdditions.add(result);
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
      paginationError = failure.toString();
    } finally {
      if (requestVersion == _requestVersion) {
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<_PageBatch> _loadPages({
    required SourceId selectedSource,
    required FeedChannel selectedChannel,
    required String query,
    Map<SourceId, String> cursors = const <SourceId, String>{},
    Set<SourceId>? onlySources,
  }) async {
    final sources =
        switch (selectedSource) {
              SourceId.xhs => <FeedSource>[xhs],
              SourceId.tieba => <FeedSource>[tieba],
              SourceId.all => <FeedSource>[tieba, xhs],
            }
            .where((FeedSource item) => onlySources?.contains(item.id) ?? true)
            .toList();
    if (sources.isEmpty) return const _PageBatch(<_SourcePage>[], <String>[]);

    final results = await Future.wait<_PageResult>(
      sources.map((FeedSource item) async {
        try {
          final cursor = cursors[item.id] ?? '';
          final page = query.isEmpty
              ? await item.browse(selectedChannel, cursor: cursor)
              : await item.search(query, cursor: cursor);
          return _PageResult(_SourcePage(item.id, page), null);
        } catch (error) {
          return _PageResult(null, '${item.id.label}：$error');
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
    if (pages.isEmpty) throw StateError(failures.join('\n'));
    return _PageBatch(pages, failures);
  }

  Future<void> selectSource(
    SourceId value, {
    bool preserveSearch = false,
  }) async {
    if (source == value) return;
    _invalidateContent(clearItems: true);
    source = value;
    if (!preserveSearch) searchQuery = '';
    notifyListeners();
    final selectedLayout = await settings.layoutFor(value);
    if (source != value) return;
    layout = selectedLayout;
    notifyListeners();
    if (preserveSearch && searchQuery.isEmpty) return;
    await refresh(clearItems: true);
  }

  Future<void> selectChannel(FeedChannel value) async {
    if (channel == value && searchQuery.isEmpty) return;
    _invalidateContent(clearItems: true);
    channel = value;
    searchQuery = '';
    notifyListeners();
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
    _invalidateContent(clearItems: true);
    searchQuery = query;
    notifyListeners();
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
    xhs.setSearchFilters(value);
    notifyListeners();
    if (searchQuery.isNotEmpty && source != SourceId.tieba) {
      await refresh(clearItems: true);
    }
  }

  Future<void> restoreFeed() async {
    if (searchQuery.isEmpty && items.isNotEmpty) return;
    _invalidateContent(clearItems: true);
    searchQuery = '';
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

  Future<void> follow(ProfileRef profile, bool value) async {
    final target = _source(profile.source);
    if (target is! RelationshipInteractor) {
      throw StateError('${profile.source.label}暂不支持关注用户');
    }
    await (target as RelationshipInteractor).follow(profile, value);
    await settings.setFollowing(profile, value);
    value
        ? _followingProfiles.add(profile.key)
        : _followingProfiles.remove(profile.key);
    await refresh();
  }

  bool isFollowing(ProfileRef profile) =>
      _followingProfiles.contains(profile.key);

  bool isForumBlocked(String forum) =>
      _filters.blockedForums.contains(normalizeForumName(forum));

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
    await settings.setSaved(item, value);
    value ? _savedKeys.add(item.key) : _savedKeys.remove(item.key);
    _updateItem(
      item.ref,
      (FeedItem current) => current.copyWith(
        favorited: value,
        stats: current.stats.copyWith(
          favorites: _changedCount(
            current.stats.favorites,
            current.favorited,
            value,
          ),
        ),
      ),
    );
    final target = _source(item.ref.source);
    if (target is! ContentInteractor ||
        !target.capabilities.contains(SourceCapability.favorite)) {
      return null;
    }
    try {
      await (target as ContentInteractor).favorite(item.ref, value);
      return null;
    } catch (failure) {
      return value ? '已保存到本地；平台收藏同步失败：$failure' : '已从本地收藏移除；平台取消收藏失败：$failure';
    }
  }

  bool isSaved(FeedItem item) => _savedKeys.contains(item.key);

  Future<void> recordHistory(FeedItem item) => settings.addHistory(item);

  Future<List<FeedItem>> historyItems() async =>
      prepareItems(await settings.historyItems());

  Future<List<FeedItem>> savedItems() async =>
      prepareItems(await settings.savedItems());

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

  FeedSource _source(SourceId id) => switch (id) {
    SourceId.xhs => xhs,
    SourceId.tieba => tieba,
    SourceId.all => throw ArgumentError('全部不是具体数据源'),
  };

  void _updateItem(ContentRef ref, FeedItem Function(FeedItem) update) {
    var changed = false;
    items = items.map((FeedItem item) {
      if (item.ref.source != ref.source || item.ref.id != ref.id) {
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
      .map(
        (FeedItem item) => _savedKeys.contains(item.key) && !item.favorited
            ? item.copyWith(favorited: true)
            : item,
      )
      .toList();

  List<FeedComment> prepareComments(Iterable<FeedComment> values) => values
      .where((FeedComment item) => !_filters.blocksText(item.body))
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
    for (var index = 0; ; index++) {
      var added = false;
      for (final group in groups) {
        if (index < group.length) {
          result.add(group[index]);
          added = true;
        }
      }
      if (!added) return result;
    }
  }
}

class _PageResult {
  const _PageResult(this.page, this.error);
  final _SourcePage? page;
  final String? error;
}

class _SourcePage {
  const _SourcePage(this.source, this.page);
  final SourceId source;
  final FeedPage page;
}

class _PageBatch {
  const _PageBatch(this.pages, this.failures);
  final List<_SourcePage> pages;
  final List<String> failures;
}
