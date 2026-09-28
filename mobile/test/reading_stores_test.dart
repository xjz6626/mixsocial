import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/comment_drafts.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/reading_preferences.dart';
import 'package:mixsocial_mobile/src/reading_state_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  late SharedPreferencesAsync preferences;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    preferences = SharedPreferencesAsync();
  });

  test(
    'draft keys isolate platform, post, top-level and reply targets',
    () async {
      const note = ContentRef(source: SourceId.xhs, id: 'post:1');
      const thread = ContentRef(source: SourceId.tieba, id: 'post:1');
      const other = ContentRef(source: SourceId.xhs, id: 'post:2');
      const first = ContentRef(source: SourceId.xhs, id: 'reply:1');
      const second = ContentRef(source: SourceId.xhs, id: 'reply:2');
      final keys = <String>{
        CommentDraftStore.draftKey(note),
        CommentDraftStore.draftKey(thread),
        CommentDraftStore.draftKey(other),
        CommentDraftStore.draftKey(note, target: first),
        CommentDraftStore.draftKey(note, target: second),
      };
      expect(keys, hasLength(5));
      final store = CommentDraftStore(preferences);
      for (final key in keys) {
        await store.save(key, CommentDraft(body: key));
      }
      for (final key in keys) {
        expect((await store.read(key))?.body, key);
      }
    },
  );

  test('unconfirmed draft survives a fresh store instance', () async {
    await CommentDraftStore(
      preferences,
    ).save('key', const CommentDraft(body: '保留原文', unconfirmed: true));
    final draft = await CommentDraftStore(preferences).read('key');
    expect(draft?.body, '保留原文');
    expect(draft?.unconfirmed, isTrue);
  });

  test('confirmed old submission never deletes newer draft', () async {
    final first = CommentDraftStore(preferences);
    final second = CommentDraftStore(preferences);
    await first.save('key', const CommentDraft(body: '已发送正文'));
    await second.save('key', const CommentDraft(body: '后续编辑'));
    await first.clear('key', expectedBody: '已发送正文');
    expect((await second.read('key'))?.body, '后续编辑');
    await first.clear('key', expectedBody: '后续编辑');
    expect(await second.read('key'), isNull);
  });

  test('draft writes across instances retain invocation order', () async {
    final first = CommentDraftStore(preferences);
    final second = CommentDraftStore(preferences);
    await Future.wait<void>(<Future<void>>[
      first.save('key', const CommentDraft(body: 'one')),
      second.save('key', const CommentDraft(body: 'two')),
      first.clear('key'),
      second.save('key', const CommentDraft(body: 'last')),
    ]);
    expect((await first.read('key'))?.body, 'last');
  });

  test('empty and corrupted drafts are safe', () async {
    final store = CommentDraftStore(preferences);
    await store.save('key', const CommentDraft(body: 'body'));
    await store.save('key', const CommentDraft(body: ''));
    expect(await store.read('key'), isNull);
    await preferences.setString('comment.draft.v1.key', '{broken');
    expect(await store.read('key'), isNull);
    await preferences.setString('comment.draft.v1.key', '{"body":34}');
    expect(await store.read('key'), isNull);
  });

  test('reading page and exact comment anchor survive reopening', () async {
    final value = ReadingState(
      page: 4,
      offset: -18,
      floor: 98,
      anchorId: 'reply-98',
      reverse: true,
      onlyOriginalPoster: true,
      updatedAt: DateTime(2026),
    );
    await ReadingStateStore(preferences).save('tieba:post', value);
    final restored = await ReadingStateStore(preferences).get('tieba:post');
    expect(restored?.page, 4);
    expect(restored?.offset, -18);
    expect(restored?.floor, 98);
    expect(restored?.anchorId, 'reply-98');
    expect(restored?.reverse, isTrue);
    expect(restored?.onlyOriginalPoster, isTrue);
    expect(restored?.label, '读到第 4 页 · 98 楼');
  });

  test(
    'library completion is not undone by stale detail scroll state',
    () async {
      final detail = ReadingStateStore(preferences);
      final library = ReadingStateStore(preferences);
      await detail.save('key', ReadingState(updatedAt: DateTime(2026)));
      await Future.wait<void>(<Future<void>>[
        library.setCompleted('key', true),
        detail.save('key', ReadingState(page: 3, updatedAt: DateTime(2026))),
      ]);
      expect((await detail.get('key'))?.completed, isTrue);
      expect((await detail.get('key'))?.page, 3);
      expect((await detail.get('key'))?.label, '已读');
      await library.setCompleted('key', false);
      expect((await detail.get('key'))?.completed, isFalse);
    },
  );

  test(
    'reading states remain independent and readable as library index',
    () async {
      final store = ReadingStateStore(preferences);
      await store.save(
        'tieba:a',
        ReadingState(page: 2, updatedAt: DateTime(2026)),
      );
      await store.setCompleted('xhs:a', true);
      final all = await ReadingStateStore(preferences).all();
      expect(all.keys.toSet(), <String>{'tieba:a', 'xhs:a'});
      expect(all['tieba:a']?.completed, isFalse);
      expect(all['xhs:a']?.completed, isTrue);
    },
  );

  test('reading state bounds damaged and non-finite input', () async {
    final state = ReadingState.fromJson(<String, dynamic>{
      'page': -6,
      'floor': -5,
      'offset': double.infinity,
    });
    expect(state.page, 1);
    expect(state.floor, 0);
    expect(state.offset, 0);
    final store = ReadingStateStore(preferences);
    await store.save(
      'key',
      ReadingState(page: 999999, offset: double.nan, updatedAt: DateTime(2026)),
    );
    expect((await store.get('key'))?.page, 100000);
    expect((await store.get('key'))?.offset, 0);
    await preferences.setString('reading.position.v1.key', 'broken');
    expect(await store.get('key'), isNull);
  });

  test('reading preferences persist and clamp safely', () async {
    final store = ReadingPreferencesStore(preferences);
    expect((await store.read()).fontSize, 16);
    await store.save(const ReadingPreferences(fontSize: 22, lineHeight: 2));
    expect((await ReadingPreferencesStore(preferences).read()).fontSize, 22);
    expect((await store.read()).lineHeight, 2);
    await preferences.setString(
      'reading.preferences.v1',
      jsonEncode(<String, Object>{'fontSize': 99, 'lineHeight': -2}),
    );
    expect((await store.read()).fontSize, 26);
    expect((await store.read()).lineHeight, 1.2);
    await preferences.setString('reading.preferences.v1', '{broken');
    expect((await store.read()).fontSize, 16);
  });
}
