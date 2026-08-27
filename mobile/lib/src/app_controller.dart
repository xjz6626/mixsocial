import 'package:flutter/foundation.dart';

import 'local_settings.dart';
import 'models.dart';
import 'source.dart';
import 'tieba_source.dart';
import 'xhs_web_source.dart';

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
  String searchQuery = '';
  Set<String> _blockedProfiles = <String>{};
  Set<String> _followingProfiles = <String>{};

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
    controller._blockedProfiles = await controller.settings.blockedProfiles();
    controller._followingProfiles = await controller.settings
        .followingProfiles();
    return controller;
  }

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final pages = await _loadPages(
        (FeedSource source) => searchQuery.isEmpty
            ? source.browse(channel)
            : source.search(searchQuery),
      );
      items = _filterBlocked(
        _roundRobin(pages.map((FeedPage page) => page.items).toList()),
      );
      notices = pages.expand((FeedPage page) => page.notices).toList();
      if (items.isEmpty && notices.isEmpty) {
        notices = const <String>['当前频道没有内容'];
      }
    } catch (failure) {
      error = failure.toString();
      items = const <FeedItem>[];
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<List<FeedPage>> _loadPages(
    Future<FeedPage> Function(FeedSource) load,
  ) async {
    final sources = switch (source) {
      SourceId.xhs => <FeedSource>[xhs],
      SourceId.tieba => <FeedSource>[tieba],
      SourceId.all => <FeedSource>[tieba, xhs],
    };
    if (sources.length == 1) return <FeedPage>[await load(sources.single)];

    final results = await Future.wait<_PageResult>(
      sources.map((FeedSource item) async {
        try {
          return _PageResult(await load(item), null);
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
    if (failures.isNotEmpty) pages.add(FeedPage(notices: failures));
    return pages;
  }

  Future<void> selectSource(SourceId value) async {
    if (source == value) return;
    source = value;
    searchQuery = '';
    layout = await settings.layoutFor(value);
    notifyListeners();
    await refresh();
  }

  Future<void> selectChannel(FeedChannel value) async {
    if (channel == value && searchQuery.isEmpty) return;
    channel = value;
    searchQuery = '';
    notifyListeners();
    await refresh();
  }

  Future<void> toggleLayout() async {
    layout = layout == FeedLayout.masonry
        ? FeedLayout.list
        : FeedLayout.masonry;
    await settings.setLayout(source, layout);
    notifyListeners();
  }

  Future<void> search(String value) async {
    searchQuery = value.trim();
    await refresh();
  }

  Future<FeedDetail> detail(ContentRef ref) => _source(ref.source).detail(ref);

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

  bool isBlocked(ProfileRef profile) => _blockedProfiles.contains(profile.key);

  // Local filtering is committed first. A remote block failure therefore does
  // not allow the author to reappear; callers receive the warning to display.
  Future<String?> block(ProfileRef profile, bool value) async {
    await settings.setBlocked(profile, value);
    value
        ? _blockedProfiles.add(profile.key)
        : _blockedProfiles.remove(profile.key);
    items = _filterBlocked(items);
    notifyListeners();

    final target = _source(profile.source);
    if (target is! RelationshipInteractor) {
      return value
          ? '${profile.source.label}仅执行了本地屏蔽'
          : '${profile.source.label}仅解除了本地屏蔽';
    }
    try {
      await (target as RelationshipInteractor).block(profile, value);
      return null;
    } catch (failure) {
      return value ? '本地屏蔽已生效；平台同步失败：$failure' : '本地屏蔽已解除；平台解除失败：$failure';
    }
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

  Future<void> favorite(ContentRef ref, bool value) async {
    await _contentAction(
      ref,
      (ContentInteractor source) => source.favorite(ref, value),
    );
    _updateItem(
      ref,
      (FeedItem item) => item.copyWith(
        favorited: value,
        stats: item.stats.copyWith(
          favorites: _changedCount(item.stats.favorites, item.favorited, value),
        ),
      ),
    );
  }

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

  List<FeedItem> _filterBlocked(Iterable<FeedItem> values) => values
      .where(
        (FeedItem item) =>
            item.author.ref.id.isEmpty ||
            !_blockedProfiles.contains(item.author.ref.key),
      )
      .toList();

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
  final FeedPage? page;
  final String? error;
}
