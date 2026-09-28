import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class LocalCollection {
  const LocalCollection({
    required this.id,
    required this.name,
    required this.itemCount,
  });

  final int id;
  final String name;
  final int itemCount;
}

class LibraryMetadata {
  const LibraryMetadata({
    this.readLater = false,
    this.readingProgress = 0,
    this.tags = const <String>[],
    this.collectionIds = const <int>{},
  });

  final bool readLater;
  final double readingProgress;
  final List<String> tags;
  final Set<int> collectionIds;
}

class LocalDatabase {
  LocalDatabase._(this._database, this._clock);

  static const int schemaVersion = 2;
  static const Duration feedLifetime = Duration(days: 7);
  static const int historyLimit = 100;
  static const int savedLimit = 300;
  static const int readLaterLimit = 300;
  static const int feedLimit = 120;

  final Database _database;
  final DateTime Function() _clock;
  int _lastTimestamp = 0;

  static Future<LocalDatabase> open({
    DatabaseFactory? factory,
    String? databasePath,
    DateTime Function()? clock,
  }) async {
    final selectedFactory = factory ?? databaseFactory;
    final selectedPath =
        databasePath ??
        path.join(await getDatabasesPath(), 'mixsocial-library.db');
    final database = await selectedFactory.openDatabase(
      selectedPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (Database database) async {
          await database.execute('PRAGMA foreign_keys = ON');
          await database.execute('PRAGMA auto_vacuum = INCREMENTAL');
        },
        onCreate: (Database database, int version) async {
          await database.execute('''
CREATE TABLE content_items (
  item_key TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  payload TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
          await database.execute('''
CREATE TABLE library_entries (
  item_key TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('history', 'saved')),
  touched_at INTEGER NOT NULL,
  PRIMARY KEY (item_key, kind),
  FOREIGN KEY (item_key) REFERENCES content_items(item_key) ON DELETE CASCADE
)
''');
          await database.execute('''
CREATE TABLE feed_entries (
  feed_key TEXT NOT NULL,
  item_key TEXT NOT NULL,
  position INTEGER NOT NULL,
  cached_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (feed_key, item_key),
  FOREIGN KEY (item_key) REFERENCES content_items(item_key) ON DELETE CASCADE
)
''');
          await database.execute(
            'CREATE INDEX library_kind_touched ON library_entries(kind, touched_at DESC)',
          );
          await database.execute(
            'CREATE INDEX feed_key_position ON feed_entries(feed_key, position)',
          );
          await database.execute(
            'CREATE INDEX feed_expiry ON feed_entries(expires_at)',
          );
          await _createReadingSchema(database);
        },
        onUpgrade: (Database database, int oldVersion, int newVersion) async {
          if (oldVersion < 2) await _createReadingSchema(database);
        },
      ),
    );
    final result = LocalDatabase._(database, clock ?? DateTime.now);
    await result._ensureSearchIndex();
    await result.cleanup();
    return result;
  }

  Future<bool> get hasLibraryData async {
    final rows = await _database.rawQuery('''
SELECT EXISTS(SELECT 1 FROM library_entries)
  OR EXISTS(SELECT 1 FROM feed_entries)
  OR EXISTS(SELECT 1 FROM reading_state)
  OR EXISTS(SELECT 1 FROM collection_items) AS has_data
''');
    return (rows.first['has_data'] as num?)?.toInt() == 1;
  }

  Future<List<FeedItem>> historyItems() => _libraryItems('history');

  Future<void> importLegacyLibrary({
    required List<FeedItem> history,
    required List<FeedItem> saved,
  }) async {
    final now = _nowMilliseconds();
    await _database.transaction((Transaction transaction) async {
      for (var index = 0; index < history.length; index++) {
        final item = history[index];
        await _upsertItem(transaction, item);
        await transaction.insert('library_entries', <String, Object?>{
          'item_key': item.key,
          'kind': 'history',
          'touched_at': now - index,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (var index = 0; index < saved.length; index++) {
        final item = saved[index].copyWith(favorited: true);
        await _upsertItem(transaction, item);
        await transaction.insert('library_entries', <String, Object?>{
          'item_key': item.key,
          'kind': 'saved',
          'touched_at': now - index,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await _trimLibrary(transaction, 'history', historyLimit);
      await _trimLibrary(transaction, 'saved', savedLimit);
    });
  }

  Future<void> addHistory(FeedItem item) async {
    await _database.transaction((Transaction transaction) async {
      await _upsertItem(transaction, item);
      await transaction.insert('library_entries', <String, Object?>{
        'item_key': item.key,
        'kind': 'history',
        'touched_at': _nowMilliseconds(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _trimLibrary(transaction, 'history', historyLimit);
    });
  }

  Future<void> clearHistory() async {
    await _database.transaction((Transaction transaction) async {
      await transaction.delete(
        'library_entries',
        where: 'kind = ?',
        whereArgs: <Object?>['history'],
      );
      await _deleteOrphanItems(transaction);
    });
  }

  Future<List<FeedItem>> savedItems() => _libraryItems('saved');

  Future<List<FeedItem>> readLaterItems() async {
    final rows = await _database.rawQuery('''
SELECT content_items.payload
FROM reading_state
JOIN content_items USING(item_key)
WHERE reading_state.read_later = 1
ORDER BY reading_state.updated_at DESC
''');
    return _decodeItems(rows);
  }

  Future<bool> isReadLater(String itemKey) async {
    final rows = await _database.query(
      'reading_state',
      columns: <String>['read_later'],
      where: 'item_key = ?',
      whereArgs: <Object?>[itemKey],
      limit: 1,
    );
    return rows.isNotEmpty && (rows.single['read_later'] as num?)?.toInt() == 1;
  }

  Future<void> setReadLater(FeedItem item, bool value) async {
    await _database.transaction((Transaction transaction) async {
      if (value) await _upsertItem(transaction, item);
      final now = _nowMilliseconds();
      final updated = await transaction.update(
        'reading_state',
        <String, Object?>{'read_later': value ? 1 : 0, 'updated_at': now},
        where: 'item_key = ?',
        whereArgs: <Object?>[item.key],
      );
      if (updated == 0 && value) {
        await transaction.insert('reading_state', <String, Object?>{
          'item_key': item.key,
          'read_later': value ? 1 : 0,
          'reading_progress': 0,
          'updated_at': now,
        });
      }
      await _trimReadLater(transaction);
      await _deleteOrphanItems(transaction);
    });
  }

  Future<void> setReadingProgress(FeedItem item, double progress) async {
    final normalized = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    await _database.transaction((Transaction transaction) async {
      if (normalized > 0) await _upsertItem(transaction, item);
      final now = _nowMilliseconds();
      final updated = await transaction.update(
        'reading_state',
        <String, Object?>{'reading_progress': normalized, 'updated_at': now},
        where: 'item_key = ?',
        whereArgs: <Object?>[item.key],
      );
      if (updated == 0 && normalized > 0) {
        await transaction.insert('reading_state', <String, Object?>{
          'item_key': item.key,
          'read_later': 0,
          'reading_progress': normalized,
          'updated_at': now,
        });
      }
      await _deleteOrphanItems(transaction);
    });
  }

  Future<LibraryMetadata> metadata(String itemKey) async {
    final states = await _database.query(
      'reading_state',
      columns: <String>['read_later', 'reading_progress'],
      where: 'item_key = ?',
      whereArgs: <Object?>[itemKey],
      limit: 1,
    );
    final tags = await _database.query(
      'item_tags',
      columns: <String>['tag'],
      where: 'item_key = ?',
      whereArgs: <Object?>[itemKey],
      orderBy: 'tag COLLATE NOCASE',
    );
    final collections = await _database.query(
      'collection_items',
      columns: <String>['collection_id'],
      where: 'item_key = ?',
      whereArgs: <Object?>[itemKey],
    );
    final state = states.firstOrNull;
    return LibraryMetadata(
      readLater: (state?['read_later'] as num?)?.toInt() == 1,
      readingProgress: (state?['reading_progress'] as num?)?.toDouble() ?? 0,
      tags: tags.map((row) => row['tag']! as String).toList(),
      collectionIds: collections
          .map((row) => (row['collection_id']! as num).toInt())
          .toSet(),
    );
  }

  Future<void> setTags(FeedItem item, Iterable<String> tags) async {
    final normalized = tags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .take(20)
        .toSet();
    await _database.transaction((Transaction transaction) async {
      await _upsertItem(transaction, item);
      await transaction.delete(
        'item_tags',
        where: 'item_key = ?',
        whereArgs: <Object?>[item.key],
      );
      for (final tag in normalized) {
        await transaction.insert('item_tags', <String, Object?>{
          'item_key': item.key,
          'tag': tag,
          'added_at': _nowMilliseconds(),
        });
      }
      await _updateSearchIndex(transaction, item);
    });
  }

  Future<List<LocalCollection>> collections() async {
    final rows = await _database.rawQuery('''
SELECT local_collections.collection_id, local_collections.name,
       COUNT(collection_items.item_key) AS item_count
FROM local_collections
LEFT JOIN collection_items USING(collection_id)
GROUP BY local_collections.collection_id
ORDER BY local_collections.updated_at DESC, local_collections.name COLLATE NOCASE
''');
    return rows
        .map(
          (row) => LocalCollection(
            id: (row['collection_id']! as num).toInt(),
            name: row['name']! as String,
            itemCount: (row['item_count']! as num).toInt(),
          ),
        )
        .toList();
  }

  Future<int> createCollection(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 60) {
      throw ArgumentError('收藏夹名称需为 1–60 个字符');
    }
    final now = _nowMilliseconds();
    await _database.insert('local_collections', <String, Object?>{
      'name': normalized,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _database.update(
      'local_collections',
      <String, Object?>{'updated_at': now},
      where: 'name = ? COLLATE NOCASE',
      whereArgs: <Object?>[normalized],
    );
    final rows = await _database.query(
      'local_collections',
      columns: <String>['collection_id'],
      where: 'name = ? COLLATE NOCASE',
      whereArgs: <Object?>[normalized],
      limit: 1,
    );
    return (rows.single['collection_id']! as num).toInt();
  }

  Future<void> setItemCollections(
    FeedItem item,
    Iterable<int> collectionIds,
  ) async {
    final selected = collectionIds.toSet();
    await _database.transaction((Transaction transaction) async {
      await _upsertItem(transaction, item);
      await transaction.delete(
        'collection_items',
        where: 'item_key = ?',
        whereArgs: <Object?>[item.key],
      );
      for (final collectionId in selected) {
        await transaction.insert('collection_items', <String, Object?>{
          'collection_id': collectionId,
          'item_key': item.key,
          'added_at': _nowMilliseconds(),
        });
      }
      await _deleteOrphanItems(transaction);
    });
  }

  Future<void> renameCollection(int collectionId, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 60) {
      throw ArgumentError('收藏夹名称需为 1–60 个字符');
    }
    await _database.update(
      'local_collections',
      <String, Object?>{'name': normalized, 'updated_at': _nowMilliseconds()},
      where: 'collection_id = ?',
      whereArgs: <Object?>[collectionId],
    );
  }

  Future<void> deleteCollection(int collectionId) async {
    await _database.transaction((transaction) async {
      await transaction.delete(
        'local_collections',
        where: 'collection_id = ?',
        whereArgs: <Object?>[collectionId],
      );
      await _deleteOrphanItems(transaction);
    });
  }

  Future<List<FeedItem>> organizedItems() async => _decodeItems(
    await _database.rawQuery('''
SELECT content_items.payload FROM content_items
WHERE EXISTS(SELECT 1 FROM collection_items WHERE collection_items.item_key = content_items.item_key)
OR EXISTS(SELECT 1 FROM item_tags WHERE item_tags.item_key = content_items.item_key)
ORDER BY content_items.updated_at DESC
'''),
  );

  Future<List<FeedItem>> collectionItems(int collectionId) async {
    final rows = await _database.rawQuery(
      '''
SELECT content_items.payload
FROM collection_items
JOIN content_items USING(item_key)
WHERE collection_items.collection_id = ?
ORDER BY collection_items.added_at DESC
''',
      <Object?>[collectionId],
    );
    return _decodeItems(rows);
  }

  Future<List<FeedItem>> searchLibrary(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return <FeedItem>[];
    final match = normalized
        .split(RegExp(r'\s+'))
        .map((term) => term.replaceAll('"', ''))
        .where((term) => term.isNotEmpty)
        .map((term) => '"$term"')
        .join(' AND ');
    if (match.isEmpty) return <FeedItem>[];
    try {
      final rows = await _database.rawQuery(
        '''
SELECT content_items.payload
FROM content_search
JOIN content_items ON content_items.item_key = content_search.item_key
WHERE content_search MATCH ?
AND (
  EXISTS(SELECT 1 FROM library_entries WHERE library_entries.item_key = content_items.item_key)
  OR EXISTS(SELECT 1 FROM reading_state WHERE reading_state.item_key = content_items.item_key)
  OR EXISTS(SELECT 1 FROM collection_items WHERE collection_items.item_key = content_items.item_key)
  OR EXISTS(SELECT 1 FROM item_tags WHERE item_tags.item_key = content_items.item_key)
)
ORDER BY content_items.updated_at DESC
LIMIT 200
''',
        <Object?>[match],
      );
      return _decodeItems(rows);
    } on DatabaseException {
      final rows = await _database.rawQuery(
        '''
SELECT DISTINCT content_items.payload
FROM content_items
LEFT JOIN item_tags USING(item_key)
WHERE (content_items.payload LIKE ? OR item_tags.tag LIKE ?)
AND (
  EXISTS(SELECT 1 FROM library_entries WHERE library_entries.item_key = content_items.item_key)
  OR EXISTS(SELECT 1 FROM reading_state WHERE reading_state.item_key = content_items.item_key)
  OR EXISTS(SELECT 1 FROM collection_items WHERE collection_items.item_key = content_items.item_key)
  OR EXISTS(SELECT 1 FROM item_tags WHERE item_tags.item_key = content_items.item_key)
)
ORDER BY content_items.updated_at DESC
LIMIT 200
''',
        <Object?>['%$normalized%', '%$normalized%'],
      );
      return _decodeItems(rows);
    }
  }

  Future<void> setSaved(FeedItem item, bool value) async {
    await _database.transaction((Transaction transaction) async {
      if (!value) {
        await transaction.delete(
          'library_entries',
          where: 'item_key = ? AND kind = ?',
          whereArgs: <Object?>[item.key, 'saved'],
        );
        await _deleteOrphanItems(transaction);
        return;
      }
      await _upsertItem(transaction, item.copyWith(favorited: true));
      await transaction.insert('library_entries', <String, Object?>{
        'item_key': item.key,
        'kind': 'saved',
        'touched_at': _nowMilliseconds(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _trimLibrary(transaction, 'saved', savedLimit);
    });
  }

  Future<void> saveFeedCache(
    SourceId source,
    FeedChannel channel,
    Iterable<FeedItem> items,
  ) async {
    final values = items.take(feedLimit).toList();
    final now = _nowMilliseconds();
    final expiresAt = now + feedLifetime.inMilliseconds;
    final feedKey = _feedKey(source, channel);
    await _database.transaction((Transaction transaction) async {
      await transaction.delete(
        'feed_entries',
        where: 'feed_key = ?',
        whereArgs: <Object?>[feedKey],
      );
      for (var position = 0; position < values.length; position++) {
        final item = values[position];
        await _upsertItem(transaction, item);
        await transaction.insert('feed_entries', <String, Object?>{
          'feed_key': feedKey,
          'item_key': item.key,
          'position': position,
          'cached_at': now,
          'expires_at': expiresAt,
        });
      }
      await _deleteOrphanItems(transaction);
    });
  }

  Future<List<FeedItem>> feedCache(SourceId source, FeedChannel channel) async {
    final now = _nowMilliseconds();
    final feedKey = _feedKey(source, channel);
    await _database.delete(
      'feed_entries',
      where: 'feed_key = ? AND expires_at <= ?',
      whereArgs: <Object?>[feedKey, now],
    );
    final rows = await _database.rawQuery(
      '''
SELECT content_items.payload
FROM feed_entries
JOIN content_items USING(item_key)
WHERE feed_entries.feed_key = ?
ORDER BY feed_entries.position ASC
LIMIT ?
''',
      <Object?>[feedKey, feedLimit],
    );
    return _decodeItems(rows);
  }

  Future<void> cleanup() async {
    await _database.transaction((Transaction transaction) async {
      await transaction.delete(
        'feed_entries',
        where: 'expires_at <= ?',
        whereArgs: <Object?>[_nowMilliseconds()],
      );
      await _trimReadLater(transaction);
      await _deleteOrphanItems(transaction);
    });
    await _database.execute('PRAGMA incremental_vacuum(200)');
  }

  Future<void> close() => _database.close();

  Future<void> _ensureSearchIndex() async {
    final contentCount = Sqflite.firstIntValue(
      await _database.rawQuery('SELECT COUNT(*) FROM content_items'),
    );
    final searchCount = Sqflite.firstIntValue(
      await _database.rawQuery('SELECT COUNT(*) FROM content_search'),
    );
    if (contentCount == searchCount) return;
    final rows = await _database.query(
      'content_items',
      columns: <String>['payload'],
    );
    await _database.transaction((Transaction transaction) async {
      await transaction.delete('content_search');
      for (final row in rows) {
        try {
          final decoded = jsonDecode(row['payload']! as String);
          if (decoded is Map) {
            await _updateSearchIndex(
              transaction,
              FeedItem.fromJson(decoded.cast<String, Object?>()),
            );
          }
        } catch (_) {
          // Malformed legacy content stays isolated from valid search rows.
        }
      }
    });
  }

  Future<List<FeedItem>> _libraryItems(String kind) async {
    final rows = await _database.rawQuery(
      '''
SELECT content_items.payload
FROM library_entries
JOIN content_items USING(item_key)
WHERE library_entries.kind = ?
ORDER BY library_entries.touched_at DESC
LIMIT ?
''',
      <Object?>[kind, kind == 'history' ? historyLimit : savedLimit],
    );
    final items = _decodeItems(rows);
    return kind == 'saved'
        ? items.map((item) => item.copyWith(favorited: true)).toList()
        : items;
  }

  List<FeedItem> _decodeItems(List<Map<String, Object?>> rows) {
    final values = <FeedItem>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row['payload']! as String);
        if (decoded is Map) {
          values.add(FeedItem.fromJson(decoded.cast<String, Object?>()));
        }
      } catch (_) {
        // A single malformed row should not hide the rest of the library.
      }
    }
    return values;
  }

  Future<void> _upsertItem(DatabaseExecutor executor, FeedItem item) async {
    final values = <String, Object?>{
      'source': item.ref.source.id,
      'payload': jsonEncode(item.toJson()),
      'updated_at': _nowMilliseconds(),
    };
    final updated = await executor.update(
      'content_items',
      values,
      where: 'item_key = ?',
      whereArgs: <Object?>[item.key],
    );
    if (updated == 0) {
      await executor.insert('content_items', <String, Object?>{
        'item_key': item.key,
        ...values,
      });
    }
    await _updateSearchIndex(executor, item);
  }

  Future<void> _updateSearchIndex(
    DatabaseExecutor executor,
    FeedItem item,
  ) async {
    final customTags = await executor.query(
      'item_tags',
      columns: <String>['tag'],
      where: 'item_key = ?',
      whereArgs: <Object?>[item.key],
    );
    await executor.delete(
      'content_search',
      where: 'item_key = ?',
      whereArgs: <Object?>[item.key],
    );
    await executor.insert('content_search', <String, Object?>{
      'item_key': item.key,
      'title': item.title,
      'summary': item.summary,
      'author': item.author.name,
      'tags': <String>[
        ...item.tags,
        ...customTags.map((row) => row['tag']! as String),
      ].join(' '),
    });
  }

  Future<void> _trimLibrary(
    DatabaseExecutor executor,
    String kind,
    int limit,
  ) async {
    await executor.rawDelete(
      '''
DELETE FROM library_entries
WHERE kind = ? AND item_key NOT IN (
  SELECT item_key FROM library_entries
  WHERE kind = ?
  ORDER BY touched_at DESC
  LIMIT ?
)
''',
      <Object?>[kind, kind, limit],
    );
    await _deleteOrphanItems(executor);
  }

  Future<void> _trimReadLater(DatabaseExecutor executor) async {
    await executor.rawUpdate(
      '''
UPDATE reading_state SET read_later = 0
WHERE read_later = 1 AND item_key NOT IN (
  SELECT item_key FROM reading_state
  WHERE read_later = 1
  ORDER BY updated_at DESC
  LIMIT ?
)
''',
      <Object?>[readLaterLimit],
    );
  }

  Future<void> _deleteOrphanItems(DatabaseExecutor executor) async {
    await executor.delete(
      'reading_state',
      where: 'read_later = 0 AND reading_progress = 0',
    );
    await executor.rawDelete('''
DELETE FROM content_items
WHERE NOT EXISTS (
  SELECT 1 FROM library_entries WHERE library_entries.item_key = content_items.item_key
)
AND NOT EXISTS (
  SELECT 1 FROM feed_entries WHERE feed_entries.item_key = content_items.item_key
)
AND NOT EXISTS (
  SELECT 1 FROM reading_state WHERE reading_state.item_key = content_items.item_key
)
AND NOT EXISTS (
  SELECT 1 FROM collection_items WHERE collection_items.item_key = content_items.item_key
)
AND NOT EXISTS (
  SELECT 1 FROM item_tags WHERE item_tags.item_key = content_items.item_key
)
''');
    await executor.rawDelete('''
DELETE FROM content_search
WHERE NOT EXISTS (
  SELECT 1 FROM content_items WHERE content_items.item_key = content_search.item_key
)
''');
  }

  int _nowMilliseconds() {
    final current = _clock().toUtc().millisecondsSinceEpoch;
    _lastTimestamp = current > _lastTimestamp ? current : _lastTimestamp + 1;
    return _lastTimestamp;
  }

  String _feedKey(SourceId source, FeedChannel channel) =>
      '${source.id}:${channel.id}';
}

Future<void> _createReadingSchema(Database database) async {
  await database.execute('''
CREATE TABLE IF NOT EXISTS reading_state (
  item_key TEXT PRIMARY KEY,
  read_later INTEGER NOT NULL DEFAULT 0,
  reading_progress REAL NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (item_key) REFERENCES content_items(item_key) ON DELETE CASCADE
)
''');
  await database.execute('''
CREATE TABLE IF NOT EXISTS local_collections (
  collection_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL COLLATE NOCASE UNIQUE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
  await database.execute('''
CREATE TABLE IF NOT EXISTS collection_items (
  collection_id INTEGER NOT NULL,
  item_key TEXT NOT NULL,
  added_at INTEGER NOT NULL,
  PRIMARY KEY (collection_id, item_key),
  FOREIGN KEY (collection_id) REFERENCES local_collections(collection_id) ON DELETE CASCADE,
  FOREIGN KEY (item_key) REFERENCES content_items(item_key) ON DELETE CASCADE
)
''');
  await database.execute('''
CREATE TABLE IF NOT EXISTS item_tags (
  item_key TEXT NOT NULL,
  tag TEXT NOT NULL COLLATE NOCASE,
  added_at INTEGER NOT NULL,
  PRIMARY KEY (item_key, tag),
  FOREIGN KEY (item_key) REFERENCES content_items(item_key) ON DELETE CASCADE
)
''');
  try {
    await database.execute('''
CREATE VIRTUAL TABLE IF NOT EXISTS content_search USING fts4(
  item_key,
  title,
  summary,
  author,
  tags,
  tokenize=unicode61
)
''');
  } on DatabaseException catch (error) {
    if (!error.toString().contains('no such module: fts4')) rethrow;
    // Some SQLite builds omit FTS4. Keep the library available and let
    // searchLibrary use its ordinary SQL fallback on those builds.
    await database.execute('''
CREATE TABLE IF NOT EXISTS content_search (
  item_key TEXT PRIMARY KEY,
  title TEXT,
  summary TEXT,
  author TEXT,
  tags TEXT
)
''');
  }
  await database.execute(
    'CREATE INDEX IF NOT EXISTS reading_later_updated ON reading_state(read_later, updated_at DESC)',
  );
  await database.execute(
    'CREATE INDEX IF NOT EXISTS collection_item_added ON collection_items(collection_id, added_at DESC)',
  );
}
