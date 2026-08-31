import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'content_filters.dart';
import 'design_system.dart';
import 'models.dart';

class LocalSettings {
  LocalSettings(this._preferences);

  final SharedPreferencesAsync _preferences;

  static Future<LocalSettings> create() async =>
      LocalSettings(SharedPreferencesAsync());

  Future<FeedLayout> layoutFor(SourceId source) async {
    final saved = await _preferences.getString('layout.${source.id}');
    if (saved == FeedLayout.list.name) return FeedLayout.list;
    if (saved == FeedLayout.masonry.name) return FeedLayout.masonry;
    return source == SourceId.tieba ? FeedLayout.list : FeedLayout.masonry;
  }

  Future<void> setLayout(SourceId source, FeedLayout layout) =>
      _preferences.setString('layout.${source.id}', layout.name);

  Future<double> scrollOffsetFor(SourceId source) async {
    final saved = await _preferences.getDouble('scroll.${source.id}');
    if (saved == null || !saved.isFinite || saved < 0) return 0;
    return saved;
  }

  Future<void> setScrollOffset(SourceId source, double offset) =>
      _preferences.setDouble(
        'scroll.${source.id}',
        offset.isFinite && offset > 0 ? offset : 0,
      );

  Future<Set<String>> blockedForums() async =>
      (await _preferences.getStringList('filters.forums') ?? const <String>[])
          .map(normalizeForumName)
          .where((String value) => value.isNotEmpty)
          .toSet();

  Future<Set<String>> blockedKeywords() async =>
      (await _preferences.getStringList('filters.keywords') ?? const <String>[])
          .map(normalizeKeyword)
          .where((String value) => value.isNotEmpty)
          .toSet();

  Future<bool> hideVideos() async =>
      await _preferences.getBool('filters.hideVideos') ?? false;

  Future<bool> hideMedia() async =>
      await _preferences.getBool('filters.hideMedia') ?? false;

  Future<FeedDensity> feedDensity() async {
    final value = await _preferences.getString('reader.density');
    return FeedDensity.values.firstWhere(
      (FeedDensity item) => item.name == value,
      orElse: () => FeedDensity.standard,
    );
  }

  Future<AppThemePreference> themePreference() async {
    final value = await _preferences.getString('appearance.theme');
    return AppThemePreference.values.firstWhere(
      (AppThemePreference item) => item.name == value,
      orElse: () => AppThemePreference.system,
    );
  }

  Future<Set<String>> followingProfiles() async =>
      (await _preferences.getStringList('relationships.following') ??
              const <String>[])
          .toSet();

  Future<void> setForumBlocked(String forum, bool value) async {
    final forums = await blockedForums();
    final normalized = normalizeForumName(forum);
    if (normalized.isEmpty) return;
    value ? forums.add(normalized) : forums.remove(normalized);
    await _preferences.setStringList('filters.forums', forums.toList()..sort());
  }

  Future<void> setKeywordBlocked(String keyword, bool value) async {
    final keywords = await blockedKeywords();
    final normalized = normalizeKeyword(keyword);
    if (normalized.isEmpty) return;
    value ? keywords.add(normalized) : keywords.remove(normalized);
    await _preferences.setStringList(
      'filters.keywords',
      keywords.toList()..sort(),
    );
  }

  Future<void> setHideVideos(bool value) =>
      _preferences.setBool('filters.hideVideos', value);

  Future<void> setHideMedia(bool value) =>
      _preferences.setBool('filters.hideMedia', value);

  Future<void> setFeedDensity(FeedDensity value) =>
      _preferences.setString('reader.density', value.name);

  Future<void> setThemePreference(AppThemePreference value) =>
      _preferences.setString('appearance.theme', value.name);

  Future<void> setFollowing(ProfileRef profile, bool value) async {
    final profiles = await followingProfiles();
    value ? profiles.add(profile.key) : profiles.remove(profile.key);
    await _preferences.setStringList(
      'relationships.following',
      profiles.toList()..sort(),
    );
  }

  Future<List<FeedItem>> historyItems() => _readItems('library.history');

  Future<void> addHistory(FeedItem item) async {
    final values = await historyItems();
    values.removeWhere((FeedItem value) => value.key == item.key);
    values.insert(0, item);
    await _writeItems('library.history', values.take(100));
  }

  Future<void> clearHistory() =>
      _preferences.setString('library.history', '[]');

  Future<List<FeedItem>> savedItems() => _readItems('library.saved');

  Future<void> setSaved(FeedItem item, bool value) async {
    final values = await savedItems();
    values.removeWhere((FeedItem existing) => existing.key == item.key);
    if (value) values.insert(0, item.copyWith(favorited: true));
    await _writeItems('library.saved', values.take(300));
  }

  Future<void> saveFeedCache(
    SourceId source,
    FeedChannel channel,
    Iterable<FeedItem> items,
  ) => _writeItems(_cacheKey(source, channel), items.take(120));

  Future<List<FeedItem>> feedCache(SourceId source, FeedChannel channel) =>
      _readItems(_cacheKey(source, channel));

  Future<List<String>> recentForums() async =>
      await _preferences.getStringList('forums.recent') ?? const <String>[];

  Future<void> addRecentForum(String forum) async {
    final normalized = normalizeForumName(forum);
    if (normalized.isEmpty) return;
    final values = await recentForums();
    values.removeWhere(
      (String value) => normalizeForumName(value) == normalized,
    );
    values.insert(0, normalized);
    await _preferences.setStringList('forums.recent', values.take(20).toList());
  }

  String _cacheKey(SourceId source, FeedChannel channel) =>
      'cache.feed.${source.id}.${channel.id}';

  Future<List<FeedItem>> _readItems(String key) async {
    final encoded = await _preferences.getString(key);
    if (encoded == null || encoded.isEmpty) return <FeedItem>[];
    try {
      return listOfMaps(jsonDecode(encoded)).map(FeedItem.fromJson).toList();
    } catch (_) {
      return <FeedItem>[];
    }
  }

  Future<void> _writeItems(String key, Iterable<FeedItem> items) =>
      _preferences.setString(
        key,
        jsonEncode(items.map((FeedItem item) => item.toJson()).toList()),
      );
}
