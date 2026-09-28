import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/detail_screen.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/reading_preferences.dart';
import 'package:mixsocial_mobile/src/reading_state_store.dart';
import 'package:mixsocial_mobile/src/social_text.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _thread = FeedItem(
  ref: ContentRef(source: SourceId.tieba, id: '12345'),
  title: '长帖阅读测试',
  author: Author(
    ref: ProfileRef(source: SourceId.tieba, id: '1'),
    id: '1',
    name: '作者',
  ),
  stats: ItemStats(),
);

class _Xhs implements XhsWebSource {
  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tieba implements TiebaSource {
  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends MixsocialController {
  _Controller()
    : super(
        xhs: _Xhs(),
        tieba: _Tieba(),
        settings: LocalSettings(SharedPreferencesAsync()),
      );
  final calls = <({String cursor, bool reverse, bool onlyOriginalPoster})>[];
  Future<FeedDetail> Function(String cursor)? onDetail;
  @override
  Future<bool> isReadLater(FeedItem item) async => true;
  @override
  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) async {
    calls.add((
      cursor: cursor,
      reverse: reverse,
      onlyOriginalPoster: onlyOriginalPoster,
    ));
    if (onDetail != null) return onDetail!(cursor);
    final page = int.tryParse(cursor) ?? 1;
    return FeedDetail(
      item: _thread,
      body: '正文内容',
      currentPage: page,
      totalPages: 6,
      comments: List<FeedComment>.generate(
        12,
        (index) => FeedComment(
          ref: ContentRef(
            source: SourceId.tieba,
            id: 'p$page-c$index',
            parentId: '12345',
          ),
          author: _thread.author,
          body: '第$page页第$index条评论\n完整内容',
          floor: (page - 1) * 12 + index + 1,
        ),
      ),
    );
  }
}

Future<void> _show(
  WidgetTester tester,
  _Controller controller, {
  ReadingStateStore? reading,
  ReadingPreferencesStore? preferences,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DetailScreen(
        controller: controller,
        initialItem: _thread,
        readingStore: reading,
        preferencesStore: preferences,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectMenu(WidgetTester tester, String value) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pumpAndSettle();
  final entry = find.byWidgetPredicate(
    (widget) =>
        widget is PopupMenuEntry<String> &&
        (widget is PopupMenuItem<String> && widget.value == value),
  );
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

void main() {
  late _Controller controller;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    controller = _Controller();
  });
  tearDown(() => controller.dispose());

  testWidgets(
    'restores persisted Tieba page, view filters and concrete comment',
    (tester) async {
      final reading = ReadingStateStore();
      await reading.save(
        _thread.key,
        ReadingState(
          page: 3,
          anchorId: 'p3-c4',
          floor: 29,
          offset: 16,
          reverse: true,
          onlyOriginalPoster: true,
          updatedAt: DateTime(2026),
        ),
      );
      await _show(tester, controller, reading: reading);
      expect(controller.calls.first.cursor, '3');
      expect(controller.calls.first.reverse, isTrue);
      expect(controller.calls.first.onlyOriginalPoster, isTrue);
      expect(find.text('已恢复上次阅读位置'), findsOneWidget);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(scroll.offset, greaterThan(200));
      expect(find.text('第3页第4条评论\n完整内容', findRichText: true), findsOneWidget);
    },
  );

  testWidgets(
    'page jump rejects zero, negatives and pages above server bound',
    (tester) async {
      await _show(tester, controller);
      await _selectMenu(tester, 'jumpPage');
      for (final input in <String>[
        '0',
        '-1',
        '7',
        '9999999999999999999999999',
      ]) {
        await tester.enterText(
          find.byKey(const Key('thread-page-input')),
          input,
        );
        await tester.tap(find.text('跳转'));
        await tester.pumpAndSettle();
        expect(find.text('请输入 1～6 的整数'), findsOneWidget);
        expect(controller.calls, hasLength(1));
      }
      await tester.enterText(find.byKey(const Key('thread-page-input')), '4');
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();
      expect(controller.calls.last.cursor, '4');
      expect(find.text('4/6 页'), findsOneWidget);
    },
  );

  testWidgets('page jump failure preserves the previous page and content', (
    tester,
  ) async {
    await _show(tester, controller);
    controller.onDetail = (_) async => throw StateError('网络断开');
    await _selectMenu(tester, 'jumpPage');
    await tester.enterText(find.byKey(const Key('thread-page-input')), '2');
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(find.text('1/6 页'), findsOneWidget);
    expect(find.text('第1页第0条评论\n完整内容', findRichText: true), findsOneWidget);
    expect(find.textContaining('刷新失败'), findsOneWidget);
  });

  testWidgets('completed reading state is shared with the local library', (
    tester,
  ) async {
    final reading = ReadingStateStore();
    await _show(tester, controller, reading: reading);
    await _selectMenu(tester, 'completed');
    expect((await ReadingStateStore().get(_thread.key))?.completed, isTrue);
    await _selectMenu(tester, 'completed');
    expect((await ReadingStateStore().get(_thread.key))?.completed, isFalse);
  });

  testWidgets('font and line-height apply to both article and comments', (
    tester,
  ) async {
    final preferences = ReadingPreferencesStore();
    await preferences.save(
      const ReadingPreferences(fontSize: 22, lineHeight: 2),
    );
    await _show(tester, controller, preferences: preferences);
    final body = tester.widget<SocialRichText>(
      find.byWidgetPredicate(
        (widget) => widget is SocialRichText && widget.text == '正文内容',
      ),
    );
    expect(body.style?.fontSize, 22);
    expect(body.style?.height, 2);
    final comment = tester.widget<SocialRichText>(
      find.byWidgetPredicate(
        (widget) => widget is SocialRichText && widget.text.startsWith('第1页第0'),
      ),
    );
    expect(comment.style?.fontSize, 22);
    expect(comment.style?.height, 2);
    await _selectMenu(tester, 'readingSettings');
    await tester.tap(find.text('恢复默认'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect((await preferences.read()).fontSize, 16);
  });

  testWidgets('back-to-top keeps page and safely scrolls to its beginning', (
    tester,
  ) async {
    await _show(tester, controller);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(500);
    await tester.pumpAndSettle();
    await _selectMenu(tester, 'top');
    expect(scroll.offset, 0);
    expect(controller.calls, hasLength(1));
  });

  testWidgets('view change ignores an older pending page', (tester) async {
    final pending = Completer<FeedDetail>();
    await _show(tester, controller);
    controller.onDetail = (cursor) async => cursor == '2'
        ? pending.future
        : const FeedDetail(item: _thread, body: '最新排序正文');
    await _selectMenu(tester, 'jumpPage');
    await tester.enterText(find.byKey(const Key('thread-page-input')), '2');
    await tester.tap(find.text('跳转'));
    await tester.pump();
    // A pull-to-refresh may supersede a jump even though menu controls disable.
    final refresh = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    controller.onDetail = (_) async =>
        const FeedDetail(item: _thread, body: '最新刷新正文');
    await refresh.onRefresh();
    pending.complete(
      const FeedDetail(item: _thread, body: '过时正文', currentPage: 2),
    );
    await tester.pumpAndSettle();
    expect(find.text('最新刷新正文', findRichText: true), findsOneWidget);
    expect(find.text('过时正文', findRichText: true), findsNothing);
  });
}
