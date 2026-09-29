import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'content_filters.dart';
import 'design_system.dart';
import 'local_database.dart';
import 'library_organizer.dart';
import 'models.dart';

class LocalSettings {
  LocalSettings(this._preferences, [this._database]);

  final SharedPreferencesAsync _preferences;
  final LocalDatabase? _database;
  late final LibraryOrganizerStore organization = LibraryOrganizerStore(
    preferences: _preferences,
    database: _database,
  );
  Future<void> _readLaterWrites = Future<void>.value();
  Future<void>? _relationshipWrites;

  bool get databaseEnabled => _database != null;

  static Future<LocalSettings> create({
    SharedPreferencesAsync? preferences,
    LocalDatabase? database,
  }) async {
    final selectedPreferences = preferences ?? SharedPreferencesAsync();
    var selectedDatabase = database;
    if (selectedDatabase == null) {
      try {
        selectedDatabase = await LocalDatabase.open();
      } catch (_) {
        // Keep the reader usable on devices whose SQLite service fails to open.
        // Existing SharedPreferences data remains the recovery path.
      }
    }
    final settings = LocalSettings(selectedPreferences, selectedDatabase);
    await settings._migrateLegacyStorage();
    await settings._migrateReadLater();
    return settings;
  }

  Future<FeedLayout> layoutFor(SourceId source) async {
    final saved = await _preferences.getString('layout.${source.id}');
    if (saved == FeedLayout.list.name) return FeedLayout.list;
    if (saved == FeedLayout.masonry.name) return FeedLayout.masonry;
    return source == SourceId.tieba || source == SourceId.zhihu
        ? FeedLayout.list
        : FeedLayout.masonry;
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

  Future<void> setFollowing(ProfileRef profile, bool value) {
    final write = (_relationshipWrites ?? Future<void>.value()).then((_) async {
      final profiles = await followingProfiles();
      value ? profiles.add(profile.key) : profiles.remove(profile.key);
      await _preferences.setStringList(
        'relationships.following',
        profiles.toList()..sort(),
      );
    });
    _relationshipWrites = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> mergeFollowingProfiles(Iterable<String> values) async {
    final profiles = await followingProfiles();
    profiles.addAll(values.where((value) => value.trim().isNotEmpty));
    await _preferences.setStringList(
      'relationships.following',
      profiles.toList()..sort(),
    );
  }

  Future<List<FeedItem>> historyItems() =>
      _database?.historyItems() ?? _readItems('library.history');

  Future<void> addHistory(FeedItem item) async {
    if (_database != null) return _database.addHistory(item);
    final values = await historyItems();
    values.removeWhere((FeedItem value) => value.key == item.key);
    values.insert(0, item);
    await _writeItems('library.history', values.take(100));
  }

  Future<void> clearHistory() =>
      _database?.clearHistory() ??
      _preferences.setString('library.history', '[]');

  Future<List<FeedItem>> savedItems() =>
      _database?.savedItems() ?? _readItems('library.saved');

  Future<void> removeRecentForum(String forum) async {
    final normalized = normalizeForumName(forum);
    final values = await recentForums();
    values.removeWhere((value) => normalizeForumName(value) == normalized);
    await _preferences.setStringList('forums.recent', values);
  }

  Future<void> clearRecentForums() =>
      _preferences.setStringList('forums.recent', <String>[]);

  Future<void> setSaved(FeedItem item, bool value) async {
    if (_database != null) return _database.setSaved(item, value);
    final values = await savedItems();
    values.removeWhere((FeedItem existing) => existing.key == item.key);
    if (value) values.insert(0, item.copyWith(favorited: true));
    await _writeItems('library.saved', values.take(300));
  }

  Future<List<FeedItem>> readLaterItems() async {
    await _readLaterWrites;
    final database = _database;
    if (database != null) return database.readLaterItems();
    return (await _readReadLaterState()).items;
  }

  Future<bool> isReadLater(String itemKey) async {
    await _readLaterWrites;
    final database = _database;
    if (database != null) return database.isReadLater(itemKey);
    return (await _readReadLaterState()).items.any(
      (FeedItem item) => item.key == itemKey,
    );
  }

  Future<void> setReadLater(FeedItem item, bool value) {
    // SharedPreferences updates read and replace a whole list. Serialize them
    // so rapid taps on different cards cannot overwrite one another.
    final write = _readLaterWrites.then((_) async {
      final state = await _readReadLaterState();
      final database = _database;
      if (database != null) {
        // Establish SQLite as authoritative before committing a change. If this
        // marker cannot be written, the requested database mutation has not run.
        if (!state.sqliteAuthoritative) {
          await _writeReadLaterState(_ReadLaterState(items: state.items));
        }
        await database.setReadLater(item, value);
        await _backupReadLater(database);
        return;
      }
      final values = state.items;
      final changes = !state.sqliteAuthoritative
          ? state.changes
          : <String, _ReadLaterChange>{};
      void recordChange(FeedItem changedItem, bool queued) {
        final previous = changes.remove(changedItem.key);
        final initiallyQueued =
            previous?.initiallyQueued ??
            values.any((FeedItem value) => value.key == changedItem.key);
        // Adding and then removing a new item cancels its pending change. This
        // bounds the journal to the original queue plus the current queue.
        if (queued || initiallyQueued) {
          changes[changedItem.key] = _ReadLaterChange(
            changedItem,
            queued,
            initiallyQueued,
          );
        }
      }

      recordChange(item, value);
      values.removeWhere((FeedItem existing) => existing.key == item.key);
      if (value) values.insert(0, item);
      for (final evicted in values.skip(LocalDatabase.readLaterLimit)) {
        recordChange(evicted, false);
      }
      // Queue, pending changes, and authority are one atomic preference write.
      // A failed write cannot leave a visible queue with a stale recovery flag.
      await _writeReadLaterState(
        _ReadLaterState(
          items: values.take(LocalDatabase.readLaterLimit).toList(),
          changes: changes,
          sqliteAuthoritative: false,
        ),
      );
    });
    // A failed write is reported to its caller, while later retries still run.
    _readLaterWrites = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<void> saveFeedCache(
    SourceId source,
    FeedChannel channel,
    Iterable<FeedItem> items,
  ) =>
      _database?.saveFeedCache(source, channel, items) ??
      _writeItems(_cacheKey(source, channel), items.take(120));

  Future<List<FeedItem>> feedCache(SourceId source, FeedChannel channel) =>
      _database?.feedCache(source, channel) ??
      _readItems(_cacheKey(source, channel));

  Future<List<String>> recentForums() async =>
      (await _preferences.getStringList('forums.recent') ?? <String>[])
          .toList();

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

  Future<void> _migrateLegacyStorage() async {
    final database = _database;
    if (database == null ||
        await _preferences.getBool('storage.sqliteMigrated.v1') == true) {
      return;
    }
    final history = await _readItems('library.history');
    final saved = await _readItems('library.saved');
    await database.importLegacyLibrary(history: history, saved: saved);
    for (final source in SourceId.values) {
      for (final channel in FeedChannel.values) {
        final cached = await _readItems(_cacheKey(source, channel));
        if (cached.isNotEmpty) {
          await database.saveFeedCache(source, channel, cached);
        }
      }
    }
    await _preferences.setBool('storage.sqliteMigrated.v1', true);
  }

  Future<void> _migrateReadLater() async {
    final database = _database;
    if (database == null) return;
    final state = await _readReadLaterState();
    if (!state.sqliteAuthoritative) {
      // Replay only actual fallback edits. An older recovery snapshot cannot
      // erase newer SQLite items or resurrect items already removed there.
      for (final change in state.changes.values) {
        await database.setReadLater(change.item, change.value);
      }
      // Do not expose a partially restored instance if this checkpoint fails.
      await _writeReadLaterState(
        _ReadLaterState(items: await database.readLaterItems()),
      );
      return;
    }
    await _backupReadLater(database);
  }

  Future<_ReadLaterState> _readReadLaterState() async {
    final encoded = await _preferences.getString('library.readLaterState.v1');
    if (encoded == null) {
      final seen = <String>{};
      final items = (await _readItems('library.readLater'))
          .where((item) => seen.add(item.key))
          .take(LocalDatabase.readLaterLimit)
          .toList();
      return _ReadLaterState(
        items: items,
        changes: <String, _ReadLaterChange>{
          for (final item in items.reversed)
            item.key: _ReadLaterChange(item, true, false),
        },
        sqliteAuthoritative: items.isEmpty,
      );
    }
    try {
      final decoded = jsonDecode(encoded) as Map;
      final seen = <String>{};
      final items = (decoded['items'] as List)
          .map(
            (value) =>
                FeedItem.fromJson((value as Map).cast<String, Object?>()),
          )
          .where((item) => seen.add(item.key))
          .take(LocalDatabase.readLaterLimit)
          .toList();
      final changes = (decoded['changes'] as List).map((value) {
        final row = value as Map;
        return _ReadLaterChange(
          FeedItem.fromJson((row['item'] as Map).cast<String, Object?>()),
          row['value'] as bool,
          row['initiallyQueued'] as bool,
        );
      });
      return _ReadLaterState(
        items: items,
        changes: <String, _ReadLaterChange>{
          for (final change in changes) change.item.key: change,
        },
        sqliteAuthoritative: decoded['sqliteAuthoritative'] as bool,
      );
    } catch (_) {
      // Corrupt recovery data must not replace a valid SQLite queue.
      return _ReadLaterState(items: <FeedItem>[]);
    }
  }

  Future<void> _writeReadLaterState(_ReadLaterState state) => _preferences
      .setString('library.readLaterState.v1', jsonEncode(state.toJson()));

  Future<void> _backupReadLater(LocalDatabase database) async {
    try {
      // Keep the latest queue available if SQLite cannot open on a later launch.
      await _writeReadLaterState(
        _ReadLaterState(items: await database.readLaterItems()),
      );
    } catch (_) {
      // SQLite has already committed. A failed recovery-copy refresh must not
      // report the action as failed or mark an older copy for reimport.
    }
  }
}

class _ReadLaterState {
  _ReadLaterState({
    required this.items,
    this.changes = const <String, _ReadLaterChange>{},
    this.sqliteAuthoritative = true,
  });

  final List<FeedItem> items;
  final Map<String, _ReadLaterChange> changes;
  final bool sqliteAuthoritative;

  Map<String, Object?> toJson() => <String, Object?>{
    'items': items.map((item) => item.toJson()).toList(),
    'changes': changes.values.map((change) => change.toJson()).toList(),
    'sqliteAuthoritative': sqliteAuthoritative,
  };
}

class _ReadLaterChange {
  const _ReadLaterChange(this.item, this.value, this.initiallyQueued);

  final FeedItem item;
  final bool value;
  final bool initiallyQueued;

  Map<String, Object?> toJson() => <String, Object?>{
    'item': item.toJson(),
    'value': value,
    'initiallyQueued': initiallyQueued,
  };
}
