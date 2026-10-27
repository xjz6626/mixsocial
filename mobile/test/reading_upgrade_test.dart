import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/comment_drafts.dart';
import 'package:mixsocial_mobile/src/content_identity_migration.dart';
import 'package:mixsocial_mobile/src/local_database.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/offline_screen.dart';
import 'package:mixsocial_mobile/src/offline_store.dart';
import 'package:mixsocial_mobile/src/reading_state_store.dart';
import 'package:mixsocial_mobile/src/structured_body.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

FeedItem item(String kind) => FeedItem(
  ref: ContentRef(source: SourceId.zhihu, id: '42', token: kind),
  title: '阅读样本',
  author: const Author(
    ref: ProfileRef(source: SourceId.zhihu, id: 'a'),
    id: 'a',
    name: '作者',
  ),
  stats: const ItemStats(),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );

  test(
    'question, answer, and article with the same numeric id stay independent',
    () {
      expect(
        [
          item('question'),
          item('answer'),
          item('article'),
        ].map((value) => value.key).toSet(),
        hasLength(3),
      );
      expect(
        ContentRef.fromJson({
          'source': 'zhihu',
          'id': '42',
          'url': 'https://zhuanlan.zhihu.com/p/42',
        }).key,
        'zhihu:article:42',
      );
    },
  );
  test(
    'legacy positions and drafts migrate once without resurrecting cleared drafts',
    () async {
      final prefs = SharedPreferencesAsync();
      await ReadingStateStore(prefs).save(
        'zhihu:42',
        ReadingState(page: 3, anchorId: 'reply', updatedAt: DateTime.now()),
      );
      final drafts = CommentDraftStore(prefs);
      await drafts.save(
        'zhihu:42:comment',
        const CommentDraft(body: '未发出的草稿', unconfirmed: true),
      );
      await migrateContentPreferences(prefs, [item('answer')]);
      expect((await ReadingStateStore(prefs).get(item('answer').key))!.page, 3);
      final key = CommentDraftStore.draftKey(item('answer').ref);
      expect((await drafts.read(key))!.unconfirmed, true);
      expect(await drafts.read('zhihu:42:comment'), isNull);
      await drafts.clear(key);
      await migrateContentPreferences(prefs, [item('answer')]);
      expect(await drafts.read(key), isNull);
    },
  );
  test(
    'ambiguous legacy state is preserved without assigning it to another type',
    () async {
      final prefs = SharedPreferencesAsync();
      final drafts = CommentDraftStore(prefs);
      await drafts.save('zhihu:42:comment', const CommentDraft(body: '保留'));
      await migrateContentPreferences(prefs, [
        item('answer'),
        item('question'),
      ]);
      expect((await drafts.read('zhihu:42:comment'))!.body, '保留');
      expect(
        await drafts.read(CommentDraftStore.draftKey(item('answer').ref)),
        isNull,
      );
    },
  );
  test(
    'v2 SQLite upgrade keeps collection, tags, progress, cache and saved identity',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'mixsocial-migration-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final path = '${temporary.path}/library.db';
      var database = await LocalDatabase.open(
        factory: databaseFactoryFfi,
        databasePath: path,
      );
      final answer = item('answer');
      await database.setSaved(answer, true);
      await database.setReadLater(answer, true);
      await database.setReadingProgress(answer, .7);
      await database.setTags(answer, ['待研究']);
      final collection = await database.createCollection('专题');
      await database.setItemCollections(answer, [collection]);
      await database.saveFeedCache(SourceId.zhihu, FeedChannel.recommend, [
        answer,
      ]);
      await database.close();
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.execute('PRAGMA foreign_keys = OFF');
      for (final table in [
        'content_items',
        'library_entries',
        'reading_state',
        'item_tags',
        'collection_items',
        'feed_entries',
        'content_search',
      ]) {
        await raw.update(
          table,
          {'item_key': 'zhihu:42'},
          where: 'item_key = ?',
          whereArgs: [answer.key],
        );
      }
      final payload = answer.toJson();
      (payload['ref'] as Map).remove('kind');
      await raw.update('content_items', {'payload': jsonEncode(payload)});
      await raw.setVersion(2);
      await raw.close();
      database = await LocalDatabase.open(
        factory: databaseFactoryFfi,
        databasePath: path,
      );
      addTearDown(database.close);
      expect((await database.savedItems()).single.key, answer.key);
      expect(
        (await database.feedCache(
          SourceId.zhihu,
          FeedChannel.recommend,
        )).single.key,
        answer.key,
      );
      final metadata = await database.metadata(answer.key);
      expect(metadata.readLater, true);
      expect(metadata.readingProgress, .7);
      expect(metadata.tags, ['待研究']);
      expect(metadata.collectionIds, {collection});
    },
  );
  test(
    'structured reading keeps text/image/link/code order and drops active content',
    () {
      final blocks = parseReadingBlocks(
        '<h2>标题</h2><p>前文</p><img data-original="https://pic.zhimg.com/high.jpg" src="https://pic.zhimg.com/low.jpg"><p>后文</p><blockquote>引用</blockquote><pre>a &lt; b</pre><a href="https://link.zhihu.com/?target=https%3A%2F%2Fexample.com">来源</a><script>bad()</script><iframe src="https://example.com"></iframe>',
      );
      expect(blocks.map((value) => value.kind), [
        'heading',
        'text',
        'image',
        'text',
        'quote',
        'code',
        'link',
      ]);
      expect(blocks[2].media!.url, endsWith('high.jpg'));
      expect(blocks.last.url, 'https://example.com');
      expect(blocks.map((value) => value.text).join(), isNot(contains('bad')));
    },
  );
  test(
    'offline quota failure preserves old body and selected image bytes',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'mixsocial-offline-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final store = OfflineStore(directory: temporary, quotaBytes: 2048);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await store.save(FeedDetail(item: item('answer'), body: '原来的正文'), {
        'https://pic.zhimg.com/image': bytes,
      });
      await expectLater(
        store.save(FeedDetail(item: item('answer'), body: '过大' * 3000), {}),
        throwsFormatException,
      );
      final saved = (await store.read(item('answer').key))!;
      expect(saved.detail.body, '原来的正文');
      expect(saved.images.values.single, bytes);
      expect(await store.list(), hasLength(1));
      await store.remove(item('answer').key);
      expect(await store.read(item('answer').key), isNull);
    },
  );
  testWidgets(
    'offline route renders HTML text with no remote images or requests',
    (tester) async {
      final entry = OfflineEntry(
        detail: FeedDetail(
          item: item('answer'),
          body: '正文',
          contentHtml:
              '<p>保存的正文</p><img src="https://pic.zhimg.com/missing.jpg">',
        ),
        savedAt: DateTime(2026),
      );
      await tester.pumpWidget(
        MaterialApp(home: OfflineReadingScreen(entry: entry)),
      );
      expect(find.text('保存的正文'), findsOneWidget);
      expect(find.text('此图片未下载'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );
}
