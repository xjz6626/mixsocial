import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/library_organizer.dart';
import 'package:mixsocial_mobile/src/local_database.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

FeedItem item(String id) => FeedItem(ref: ContentRef(source: SourceId.tieba, id: id), title: '帖子 $id', author: const Author(ref: ProfileRef(source: SourceId.tieba, id: 'author'), id: 'author', name: '作者'), stats: const ItemStats());

void main() {
  sqfliteFfiInit();
  late SharedPreferencesAsync preferences;
  late LocalDatabase database;
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    preferences = SharedPreferencesAsync();
    database = await LocalDatabase.open(factory: databaseFactoryFfi, databasePath: inMemoryDatabasePath);
  });
  tearDown(() => database.close());

  test('SQLite collection rename and deletion retain saved and tagged content', () async {
    final id = await database.createCollection('技术');
    await database.setSaved(item('1'), true);
    await database.setTags(item('2'), ['只加标签']);
    await database.setItemCollections(item('1'), [id]);
    await database.setItemCollections(item('2'), [id]);
    await database.renameCollection(id, '阅读');
    expect((await database.collections()).single.name, '阅读');
    await database.deleteCollection(id);
    expect(await database.collections(), isEmpty);
    expect((await database.savedItems()).single.key, 'tieba:1');
    expect((await database.organizedItems()).single.key, 'tieba:2');
    expect((await database.metadata('tieba:2')).tags, ['只加标签']);
  });

  test('fallback supports CRUD tags and serialized edits across instances', () async {
    final store = LibraryOrganizerStore(preferences: preferences);
    final another = LibraryOrganizerStore(preferences: preferences);
    await Future.wait([store.create('One'), another.create('Two')]);
    await store.setMembership('one', [item('1'), item('2')], true);
    await store.setTags(item('1'), ['  Dart ', 'dart', '阅读']);
    await store.rename('One', 'Tech');
    await store.setMembership('Tech', [item('1')], false);
    final state = await store.read();
    expect(state.collections['Tech'], ['tieba:2']);
    expect(state.tags['tieba:1'], ['Dart', '阅读']);
    await store.delete('Tech');
    expect((await store.read()).items.keys, ['tieba:1']);
    await store.setTags(item('1'), []);
    expect((await store.read()).items, isEmpty);
  });

  test('fallback edits migrate without overwriting newer SQLite entries', () async {
    final connected = LibraryOrganizerStore(preferences: preferences, database: database);
    await connected.create('Keep');
    await connected.setMembership('Keep', [item('1')], true);
    final offline = LibraryOrganizerStore(preferences: preferences);
    await offline.create('Offline');
    await offline.setMembership('Offline', [item('2')], true);
    await offline.setTags(item('2'), ['pending']);
    final directId = await database.createCollection('New database only');
    await database.setItemCollections(item('3'), [directId]);
    final restored = await connected.read();
    expect(restored.collections.keys, containsAll(['Keep', 'Offline', 'New database only']));
    expect(restored.items.keys, containsAll(['tieba:1', 'tieba:2', 'tieba:3']));
    expect((await database.metadata('tieba:2')).tags, ['pending']);
    expect((await connected.read()).collections, restored.collections);
  });

  test('pending delete and rename replay idempotently without resurrecting old names', () async {
    final connected = LibraryOrganizerStore(preferences: preferences, database: database);
    await connected.create('Old');
    await connected.create('Delete');
    final offline = LibraryOrganizerStore(preferences: preferences);
    await offline.rename('Old', 'Renamed');
    await offline.delete('Delete');
    await offline.setMembership('Renamed', [item('1')], true);
    expect((await connected.read()).collections.keys, ['Renamed']);
    expect((await connected.read()).collections['Renamed'], ['tieba:1']);
  });

  test('invalid and duplicate names or excessive tags are rejected', () async {
    final store = LibraryOrganizerStore(preferences: preferences);
    await store.create('A'); await store.create('B');
    await expectLater(store.rename('A', 'b'), throwsArgumentError);
    expect(() => store.create(' '), throwsArgumentError);
    expect(() => store.setTags(item('1'), List.generate(21, (index) => '$index')), throwsArgumentError);
    expect((await store.read()).collections.keys, ['A', 'B']);
  });

  test('recent forums return mutable empty lists and support normalized removal', () async {
    final settings = LocalSettings(preferences);
    await settings.removeRecentForum('Flutter吧');
    await settings.addRecentForum('Flutter吧');
    await settings.addRecentForum('Dart');
    await settings.removeRecentForum('Flutter');
    expect(await settings.recentForums(), ['dart']);
    await settings.clearRecentForums();
    expect(await settings.recentForums(), isEmpty);
  });
}
