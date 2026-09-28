import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/local_database.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

FeedItem _item(int index, {bool favorite = false}) => FeedItem(
  ref: ContentRef(source: SourceId.tieba, id: 'thread-$index'),
  title: '主题 $index',
  author: Author(
    ref: ProfileRef(source: SourceId.tieba, id: 'author-$index'),
    id: 'author-$index',
    name: '作者 $index',
  ),
  stats: const ItemStats(),
  favorited: favorite,
);

class _FailingReadLaterPreferences extends SharedPreferencesAsync {
  _FailingReadLaterPreferences({this.backupFails, this.markerFails});

  final bool Function()? backupFails;
  final bool Function()? markerFails;

  @override
  Future<void> setString(String key, String value) {
    if ((backupFails?.call() == true || markerFails?.call() == true) &&
        key == 'library.readLaterState.v1') {
      return Future<void>.error(StateError('Recovery copy is unavailable'));
    }
    return super.setString(key, value);
  }
}

void main() {
  sqfliteFfiInit();

  late LocalDatabase database;
  var now = DateTime.utc(2026, 9, 3);

  setUp(() async {
    now = DateTime.utc(2026, 9, 3);
    database = await LocalDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
      clock: () => now,
    );
  });

  tearDown(() => database.close());

  test('SQLite history is ordered, deduplicated and bounded', () async {
    for (var index = 0; index < 105; index++) {
      await database.addHistory(_item(index));
    }
    await database.addHistory(_item(100));

    final history = await database.historyItems();
    expect(history, hasLength(LocalDatabase.historyLimit));
    expect(history.first.key, 'tieba:thread-100');
    expect(
      history.where((item) => item.key == history.first.key),
      hasLength(1),
    );
    expect(await database.hasLibraryData, isTrue);
  });

  test(
    'SQLite read later is deduplicated and bounded without losing progress',
    () async {
      await database.setReadingProgress(_item(0), 0.4);
      await database.setSaved(_item(1), true);
      for (var index = 0; index < LocalDatabase.readLaterLimit + 2; index++) {
        await database.setReadLater(_item(index), true);
      }
      await database.setReadLater(_item(8).copyWith(title: '更新标题'), true);

      final items = await database.readLaterItems();
      expect(items, hasLength(LocalDatabase.readLaterLimit));
      expect(items.first.key, _item(8).key);
      expect(items.first.title, '更新标题');
      expect(items.map((item) => item.key).toSet(), hasLength(items.length));
      expect(await database.isReadLater(_item(0).key), isFalse);
      expect(await database.isReadLater(_item(1).key), isFalse);
      expect((await database.metadata(_item(0).key)).readingProgress, 0.4);
      expect((await database.savedItems()).single.key, _item(1).key);
    },
  );

  test('removing read later preserves every other content reference', () async {
    for (var index = 0; index < 6; index++) {
      await database.setReadLater(_item(index), true);
    }
    await database.setSaved(_item(0), true);
    await database.addHistory(_item(1).copyWith(title: '历史中的更新标题'));
    await database.setReadingProgress(_item(2), 0.5);
    final collectionId = await database.createCollection('待读专题');
    await database.setItemCollections(_item(3), <int>[collectionId]);
    await database.saveFeedCache(
      SourceId.tieba,
      FeedChannel.recommend,
      <FeedItem>[_item(4)],
    );

    for (var index = 0; index < 6; index++) {
      await database.setReadLater(_item(index), false);
    }
    expect(await database.readLaterItems(), isEmpty);
    expect((await database.savedItems()).single.key, _item(0).key);
    expect((await database.historyItems()).single.title, '历史中的更新标题');
    expect((await database.metadata(_item(2).key)).readingProgress, 0.5);
    expect(
      (await database.collectionItems(collectionId)).single.key,
      _item(3).key,
    );
    expect(
      (await database.feedCache(
        SourceId.tieba,
        FeedChannel.recommend,
      )).single.key,
      _item(4).key,
    );
    expect(await database.searchLibrary('主题 5'), isEmpty);
  });

  test(
    'empty reading state is removed when queue and progress are cleared',
    () async {
      final item = _item(7);
      await database.setReadLater(item, false);
      expect(await database.hasLibraryData, isFalse);
      await database.setReadingProgress(item, 0);
      expect(await database.hasLibraryData, isFalse);

      await database.setReadLater(item, true);
      expect(await database.hasLibraryData, isTrue);
      await database.setReadingProgress(item, 0.7);
      await database.setReadLater(item, false);
      expect(await database.hasLibraryData, isTrue);
      await database.setReadingProgress(item, 0);
      expect(await database.hasLibraryData, isFalse);
      expect(await database.searchLibrary('主题'), isEmpty);
    },
  );

  test(
    'SQLite read later mirrors recovery data and reimports fallback edits',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final preferences = SharedPreferencesAsync();
      // Read-later migration must run even on installations already using SQLite.
      await preferences.setBool('storage.sqliteMigrated.v1', true);
      final fallback = LocalSettings(preferences);
      await fallback.setReadLater(_item(1), true);
      await fallback.setReadLater(_item(2), true);
      final settings = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      expect(
        (await settings.readLaterItems()).map((item) => item.key),
        <String>[_item(2).key, _item(1).key],
      );
      await Future.wait(<Future<void>>[
        settings.setReadLater(_item(3), true),
        settings.setReadLater(_item(2), false),
        settings.setReadLater(_item(4), true),
      ]);
      expect(await settings.isReadLater(_item(2).key), isFalse);
      expect(
        (await fallback.readLaterItems()).map((item) => item.key),
        <String>[_item(4).key, _item(3).key, _item(1).key],
      );

      await database.setSaved(_item(3), true);
      await fallback.setReadLater(_item(3), false);
      await fallback.setReadLater(_item(5), true);
      final restored = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      expect(
        (await restored.readLaterItems()).map((item) => item.key),
        <String>[_item(5).key, _item(4).key, _item(1).key],
      );
      expect((await restored.savedItems()).single.key, _item(3).key);
    },
  );

  test(
    'corrupt fallback data cannot erase the SQLite read later queue',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final preferences = SharedPreferencesAsync();
      await database.setReadLater(_item(9), true);
      await preferences.setString('library.readLaterState.v1', '{broken');
      final settings = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      expect((await settings.readLaterItems()).single.key, _item(9).key);
      expect(
        (await LocalSettings(preferences).readLaterItems()).single.key,
        _item(9).key,
      );
    },
  );

  test(
    'failed recovery copy does not undo or fail a successful SQLite action',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      var failBackup = false;
      final preferences = _FailingReadLaterPreferences(
        backupFails: () => failBackup,
      );
      final settings = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      await settings.setReadLater(_item(1), true);
      failBackup = true;
      await settings.setReadLater(_item(1), false);
      await settings.setReadLater(_item(2), true);
      expect((await settings.readLaterItems()).single.key, _item(2).key);
      expect(
        (jsonDecode((await preferences.getString('library.readLaterState.v1'))!)
            as Map)['sqliteAuthoritative'],
        isTrue,
      );

      failBackup = false;
      final restored = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      expect((await restored.readLaterItems()).single.key, _item(2).key);
      expect(
        (await LocalSettings(preferences).readLaterItems()).single.key,
        _item(2).key,
      );
    },
  );

  test(
    'failed recovery marker leaves SQLite unchanged and permits retry',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      var failMarker = false;
      final preferences = _FailingReadLaterPreferences(
        markerFails: () => failMarker,
      );
      final settings = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      await preferences.setString(
        'library.readLaterState.v1',
        jsonEncode(<String, Object?>{
          'items': <Object?>[],
          'changes': <Object?>[],
          'sqliteAuthoritative': false,
        }),
      );
      failMarker = true;
      await expectLater(
        settings.setReadLater(_item(1), true),
        throwsStateError,
      );
      expect(await database.readLaterItems(), isEmpty);

      failMarker = false;
      await settings.setReadLater(_item(2), true);
      expect((await settings.readLaterItems()).single.key, _item(2).key);
    },
  );

  test(
    'failed fallback writes leave the queue and recovery changes unchanged',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      var failWrites = false;
      final preferences = _FailingReadLaterPreferences(
        backupFails: () => failWrites,
      );
      final settings = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      await settings.setReadLater(_item(1), true);
      final fallback = LocalSettings(preferences);
      final before = await preferences.getString('library.readLaterState.v1');

      failWrites = true;
      await expectLater(
        fallback.setReadLater(_item(2), true),
        throwsStateError,
      );
      await expectLater(
        fallback.setReadLater(_item(1), false),
        throwsStateError,
      );
      expect(await preferences.getString('library.readLaterState.v1'), before);
      expect((await fallback.readLaterItems()).single.key, _item(1).key);

      failWrites = false;
      var restored = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      expect((await restored.readLaterItems()).single.key, _item(1).key);
      await fallback.setReadLater(_item(1), false);
      final afterRemoval = await preferences.getString(
        'library.readLaterState.v1',
      );
      failWrites = true;
      await expectLater(
        fallback.setReadLater(_item(3), true),
        throwsStateError,
      );
      expect(
        await preferences.getString('library.readLaterState.v1'),
        afterRemoval,
      );
      expect(await fallback.readLaterItems(), isEmpty);

      failWrites = false;
      restored = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      expect(await restored.readLaterItems(), isEmpty);
      await fallback.setReadLater(_item(2), true);
      restored = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      expect((await restored.readLaterItems()).single.key, _item(2).key);
    },
  );

  test(
    'fallback edits merge safely when the recovery copy is out of date',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      var failBackup = false;
      final preferences = _FailingReadLaterPreferences(
        backupFails: () => failBackup,
      );
      final settings = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      await settings.setReadLater(_item(1), true);
      failBackup = true;
      await settings.setReadLater(_item(1), false);
      await settings.setReadLater(_item(2), true);

      failBackup = false;
      final fallback = LocalSettings(preferences);
      expect((await fallback.readLaterItems()).single.key, _item(1).key);
      await fallback.setReadLater(_item(3), true);
      await fallback.setReadLater(_item(4), true);
      await fallback.setReadLater(_item(4), false);
      final restored = await LocalSettings.create(
        preferences: preferences,
        database: database,
      );
      expect(
        (await restored.readLaterItems()).map((item) => item.key),
        <String>[_item(3).key, _item(2).key],
      );
    },
  );

  test('library search and tag updates work without requiring FTS4', () async {
    final saved = _item(1).copyWith(title: 'Flutter rendering');
    await database.setSaved(saved, true);
    await database.setTags(saved, <String>['待验证']);
    await database.saveFeedCache(
      SourceId.tieba,
      FeedChannel.recommend,
      <FeedItem>[_item(2).copyWith(title: 'Flutter cached only')],
    );

    expect((await database.searchLibrary('Flutter')).single.key, saved.key);
    expect((await database.searchLibrary('待验证')).single.key, saved.key);
    expect(await database.searchLibrary('missing'), isEmpty);

    await database.setTags(saved, <String>['已验证']);
    expect(await database.searchLibrary('待验证'), isEmpty);
    expect((await database.searchLibrary('已验证')).single.key, saved.key);
    await database.setSaved(saved, false);
    // Standalone user tags are an explicit local-library reference.
    expect((await database.searchLibrary('Flutter')).single.key, saved.key);
    await database.setTags(saved, <String>[]);
    expect(await database.searchLibrary('Flutter'), isEmpty);
  });

  test(
    'saved items survive feed expiry while stale cache is removed',
    () async {
      final saved = _item(7, favorite: true);
      await database.setSaved(saved, true);
      await database.saveFeedCache(
        SourceId.tieba,
        FeedChannel.recommend,
        <FeedItem>[saved, _item(8)],
      );
      expect(
        await database.feedCache(SourceId.tieba, FeedChannel.recommend),
        hasLength(2),
      );

      now = now.add(const Duration(days: 8));
      expect(
        await database.feedCache(SourceId.tieba, FeedChannel.recommend),
        isEmpty,
      );
      expect((await database.savedItems()).single.key, saved.key);

      await database.setSaved(saved, false);
      expect(await database.savedItems(), isEmpty);
    },
  );

  test('legacy SharedPreferences content migrates once into SQLite', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final preferences = SharedPreferencesAsync();
    await preferences.setString(
      'library.history',
      jsonEncode(<Object?>[_item(2).toJson(), _item(1).toJson()]),
    );
    await preferences.setString(
      'library.saved',
      jsonEncode(<Object?>[_item(3, favorite: true).toJson()]),
    );
    await preferences.setString(
      'cache.feed.all.recommend',
      jsonEncode(<Object?>[_item(4).toJson()]),
    );

    final settings = await LocalSettings.create(
      preferences: preferences,
      database: database,
    );
    expect((await settings.historyItems()).first.key, 'tieba:thread-2');
    expect((await settings.savedItems()).single.key, 'tieba:thread-3');
    expect(
      (await settings.feedCache(
        SourceId.all,
        FeedChannel.recommend,
      )).single.key,
      'tieba:thread-4',
    );
    expect(await preferences.getBool('storage.sqliteMigrated.v1'), isTrue);

    await preferences.setString(
      'library.history',
      jsonEncode(<Object?>[_item(99).toJson()]),
    );
    final restored = await LocalSettings.create(
      preferences: preferences,
      database: database,
    );
    expect((await restored.historyItems()).first.key, 'tieba:thread-2');
  });
}
