import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_database.dart';
import 'models.dart';

/// Collection names are the portable identity; SQLite IDs never leave the device.
class LibraryOrganization {
  LibraryOrganization({
    Map<String, List<String>>? collections,
    Map<String, List<String>>? tags,
    Map<String, FeedItem>? items,
  }) : collections = collections ?? {},
       tags = tags ?? {},
       items = items ?? {};

  final Map<String, List<String>> collections;
  final Map<String, List<String>> tags;
  final Map<String, FeedItem> items;

  Map<String, Object?> toJson() => {
    'collections': collections,
    'tags': tags,
    'items': items.values.map((item) => item.toJson()).toList(),
  };

  factory LibraryOrganization.fromJson(Map<String, Object?> json) {
    Map<String, List<String>> strings(Object? value) => mapOf(value).map(
      (key, value) => MapEntry(key, listOf(value).whereType<String>().toList()),
    );
    return LibraryOrganization(
      collections: strings(json['collections']),
      tags: strings(json['tags']),
      items: {
        for (final value in listOfMaps(json['items']))
          FeedItem.fromJson(value).key: FeedItem.fromJson(value),
      },
    );
  }
}

/// SQLite is authoritative. When unavailable, one atomic JSON contains both the
/// visible fallback state and explicit edits. Recovery replays edits, never an
/// older snapshot, so newer database-only items are retained.
class LibraryOrganizerStore {
  LibraryOrganizerStore({
    required this._preferences,
    this._database,
  });

  static const preferenceKey = 'library.organization.v1';
  static Future<void>? _tail;
  final SharedPreferencesAsync _preferences;
  final LocalDatabase? _database;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = (_tail ?? Future<void>.value()).then((_) => action());
    late final Future<void> tail;
    void finished() {
      if (identical(_tail, tail)) _tail = null;
    }
    tail = result.then<void>((_) => finished(), onError: (Object _) => finished());
    _tail = tail;
    return result;
  }

  Future<LibraryOrganization> read() => _serial(() async {
    final state = await _read();
    return (await _reconcile(state)).organization;
  });

  Future<void> create(String name) =>
      _edit({'kind': 'create', 'name': _name(name)});
  Future<void> rename(String name, String newName) =>
      _edit({'kind': 'rename', 'name': _name(name), 'newName': _name(newName)});
  Future<void> delete(String name) =>
      _edit({'kind': 'delete', 'name': _name(name)});
  Future<void> setMembership(
    String name,
    Iterable<FeedItem> items,
    bool value,
  ) => _edit({
    'kind': value ? 'add' : 'remove',
    'name': _name(name),
    'items': items.map((item) => item.toJson()).toList(),
  });
  Future<void> setTags(FeedItem item, Iterable<String> tags) => _edit({
    'kind': 'tags',
    'items': [item.toJson()],
    'tags': normalizeTags(tags),
  });

  static List<String> normalizeTags(Iterable<String> tags) {
    final values = <String, String>{};
    for (final raw in tags) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      if (value.length > 40) throw ArgumentError('每个标签不能超过 40 个字符');
      values.putIfAbsent(value.toLowerCase(), () => value);
    }
    if (values.length > 20) throw ArgumentError('每条内容最多 20 个标签');
    return values.values.toList();
  }

  static String _name(String value) {
    final name = value.trim();
    if (name.isEmpty || name.length > 60) {
      throw ArgumentError('收藏夹名称需为 1–60 个字符');
    }
    return name;
  }

  Future<void> _edit(Map<String, Object?> operation) => _serial(() async {
    final state = await _reconcile(await _read());
    _apply(state.organization, operation);
    if (state.pending.length >= 4000) {
      throw StateError('待同步操作过多，请稍后重试或先导出备份');
    }
    state.pending.add(operation);
    // Journal must be durable before any database mutation is attempted.
    await _write(state);
    await _reconcile(state);
  });

  Future<_OrganizerState> _read() async {
    final raw = await _preferences.getString(preferenceKey);
    if (raw == null) return _OrganizerState(LibraryOrganization(), []);
    final json = mapOf(jsonDecode(raw));
    if (json['version'] != 1) throw const FormatException('本地收藏夹版本不受支持');
    return _OrganizerState(
      LibraryOrganization.fromJson(mapOf(json['organization'])),
      listOfMaps(json['pending']).toList(),
    );
  }

  Future<void> _write(_OrganizerState state) => _preferences.setString(
    preferenceKey,
    jsonEncode({
      'version': 1,
      'organization': state.organization.toJson(),
      'pending': state.pending,
    }),
  );

  Future<_OrganizerState> _reconcile(_OrganizerState state) async {
    final database = _database;
    if (database == null) return state;
    try {
      while (state.pending.isNotEmpty) {
        await _applyDatabase(database, state.pending.first);
        // Replay is idempotent if a crash occurs between SQLite and this write.
        final remaining = _OrganizerState(
          state.organization,
          state.pending.skip(1).toList(),
        );
        await _write(remaining);
        state = remaining;
      }
      final items = await database.organizedItems();
      final collections = await database.collections();
      final organization = LibraryOrganization(
        items: {for (final item in items) item.key: item},
      );
      for (final collection in collections) {
        organization.collections[collection.name] =
            (await database.collectionItems(
              collection.id,
            )).map((item) => item.key).toList();
      }
      for (final item in items) {
        final tags = (await database.metadata(item.key)).tags;
        if (tags.isNotEmpty) organization.tags[item.key] = tags;
      }
      final fresh = _OrganizerState(organization, []);
      try {
        await _write(fresh);
      } catch (_) {
        /* SQLite already committed. */
      }
      return fresh;
    } catch (_) {
      // Keep the durable fallback and journal usable when SQLite is unavailable.
      return state;
    }
  }

  static String? _existingName(LibraryOrganization state, String name) => state
      .collections
      .keys
      .where((key) => key.toLowerCase() == name.toLowerCase())
      .firstOrNull;

  static void _apply(LibraryOrganization state, Map<String, Object?> op) {
    final rawName = op['name'] as String? ?? '';
    final name = _existingName(state, rawName) ?? rawName;
    final items = listOfMaps(op['items']).map(FeedItem.fromJson).toList();
    switch (op['kind']) {
      case 'create':
        if (!state.collections.containsKey(name) &&
            state.collections.length >= 100) {
          throw StateError('最多创建 100 个收藏夹');
        }
        state.collections.putIfAbsent(name, () => []);
      case 'rename':
        final next = op['newName']! as String;
        final duplicate = _existingName(state, next);
        if (duplicate != null && duplicate != name) {
          throw ArgumentError('已有同名收藏夹');
        }
        if (state.collections.containsKey(name)) {
          state.collections[next] = state.collections.remove(name)!;
        }
      case 'delete':
        state.collections.remove(name);
      case 'add':
        final keys = state.collections[name];
        if (keys == null) throw StateError('收藏夹已不存在');
        for (final item in items) {
          state.items[item.key] = item;
          if (!keys.contains(item.key)) keys.add(item.key);
        }
      case 'remove':
        state.collections[name]?.removeWhere(
          (key) => items.any((item) => item.key == key),
        );
      case 'tags':
        for (final item in items) {
          state.items[item.key] = item;
          final tags = listOf(op['tags']).cast<String>();
          tags.isEmpty
              ? state.tags.remove(item.key)
              : state.tags[item.key] = tags;
        }
    }
    final retained = {
      ...state.collections.values.expand((keys) => keys),
      ...state.tags.keys,
    };
    state.items.removeWhere((key, _) => !retained.contains(key));
  }

  Future<void> _applyDatabase(
    LocalDatabase database,
    Map<String, Object?> op,
  ) async {
    final name = op['name'] as String? ?? '';
    final collections = await database.collections();
    final collection = collections
        .where((value) => value.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    final items = listOfMaps(op['items']).map(FeedItem.fromJson).toList();
    switch (op['kind']) {
      case 'create':
        await database.createCollection(name);
      case 'rename':
        if (collection != null) {
          await database.renameCollection(
            collection.id,
            op['newName']! as String,
          );
        }
      case 'delete':
        if (collection != null) await database.deleteCollection(collection.id);
      case 'add':
        final id = collection?.id ?? await database.createCollection(name);
        for (final item in items) {
          final ids = (await database.metadata(item.key)).collectionIds;
          await database.setItemCollections(item, {...ids, id});
        }
      case 'remove':
        if (collection != null) {
          for (final item in items) {
            final ids = (await database.metadata(item.key)).collectionIds
              ..remove(collection.id);
            await database.setItemCollections(item, ids);
          }
        }
      case 'tags':
        for (final item in items) {
          await database.setTags(item, listOf(op['tags']).cast<String>());
        }
    }
  }
}

class _OrganizerState {
  _OrganizerState(this.organization, this.pending);
  final LibraryOrganization organization;
  final List<Map<String, Object?>> pending;
}
