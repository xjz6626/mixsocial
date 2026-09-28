import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/detail_screen.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _note = FeedItem(
  ref: ContentRef(source: SourceId.xhs, id: '66c900000000000000000123'),
  title: '阅读测试',
  author: Author(
    ref: ProfileRef(source: SourceId.xhs, id: 'author'),
    id: 'author',
    name: '作者',
  ),
  stats: ItemStats(favorites: 7),
);

FeedComment _comment(String text) => FeedComment(
  ref: ContentRef(source: SourceId.xhs, id: text),
  author: _note.author,
  body: text,
);

class _XhsSource implements XhsWebSource {
  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{
    SourceCapability.favorite,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TiebaSource implements TiebaSource {
  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends MixsocialController {
  _Controller()
    : super(
        xhs: _XhsSource(),
        tieba: _TiebaSource(),
        settings: LocalSettings(SharedPreferencesAsync()),
      );

  bool savedCopy = false;
  bool readLater = false;
  final List<bool> readLaterWrites = <bool>[];
  Future<void> Function()? onWriteReadLater;
  Future<bool> Function()? onReadLater;
  Future<FeedDetail> Function(String cursor)? onDetail;

  @override
  bool isSaved(FeedItem item) => savedCopy;

  @override
  Future<bool> isReadLater(FeedItem item) async =>
      onReadLater == null ? readLater : await onReadLater!();

  @override
  Future<void> setReadLater(FeedItem item, bool value) async {
    readLaterWrites.add(value);
    await onWriteReadLater?.call();
    readLater = value;
    notifyListeners();
  }

  @override
  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) async => onDetail == null
      ? const FeedDetail(item: _note, body: '完整正文')
      : await onDetail!(cursor);
}

Future<void> _showDetail(WidgetTester tester, _Controller controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DetailScreen(controller: controller, initialItem: _note),
    ),
  );
  await tester.pump();
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pumpAndSettle();
}

Finder _readLaterEntry() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is CheckedPopupMenuItem<String> && widget.value == 'readLater',
);

void main() {
  late _Controller controller;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    controller = _Controller();
  });
  tearDown(() => controller.dispose());

  testWidgets('read later stays independent from Xiaohongshu favorites', (
    WidgetTester tester,
  ) async {
    await _showDetail(tester, controller);
    await _openMenu(tester);
    await tester.tap(_readLaterEntry());
    await tester.pumpAndSettle();

    expect(controller.readLater, isTrue);
    expect(controller.savedCopy, isFalse);
    expect(find.byIcon(Icons.bookmark), findsNothing);
    expect(find.text('已加入稍后阅读，可在“我的”中查看'), findsOneWidget);

    await _openMenu(tester);
    expect(find.text('移出稍后阅读'), findsOneWidget);
    await tester.tap(_readLaterEntry());
    await tester.pumpAndSettle();
    expect(controller.readLaterWrites, <bool>[true, false]);
  });

  testWidgets('failed read later write preserves state and remains retryable', (
    WidgetTester tester,
  ) async {
    controller.onWriteReadLater = () async => throw StateError('disk full');
    await _showDetail(tester, controller);
    await _openMenu(tester);
    await tester.tap(_readLaterEntry());
    await tester.pumpAndSettle();

    expect(controller.readLater, isFalse);
    expect(find.textContaining('更新稍后阅读失败'), findsOneWidget);
    await _openMenu(tester);
    expect(find.text('加入稍后阅读'), findsOneWidget);
    controller.onWriteReadLater = null;
    await tester.tap(_readLaterEntry());
    await tester.pumpAndSettle();
    expect(controller.readLater, isTrue);
  });

  testWidgets('pending read later write prevents another toggle', (
    WidgetTester tester,
  ) async {
    final pending = Completer<void>();
    controller.onWriteReadLater = () => pending.future;
    await _showDetail(tester, controller);
    await _openMenu(tester);
    await tester.tap(_readLaterEntry());
    await tester.pumpAndSettle();
    await _openMenu(tester);

    final entry = tester.widget<CheckedPopupMenuItem<String>>(
      find.ancestor(
        of: find.text('正在更新稍后阅读…'),
        matching: find.byType(CheckedPopupMenuItem<String>),
      ),
    );
    expect(entry.enabled, isFalse);
    expect(controller.readLaterWrites, <bool>[true]);
    pending.complete();
    await tester.pumpAndSettle();
    expect(controller.readLater, isTrue);
  });

  testWidgets('late initial loads are harmless after the detail is disposed', (
    WidgetTester tester,
  ) async {
    final pendingState = Completer<bool>();
    final pendingDetail = Completer<FeedDetail>();
    controller.onReadLater = () => pendingState.future;
    controller.onDetail = (_) => pendingDetail.future;
    await _showDetail(tester, controller);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pendingState.complete(true);
    pendingDetail.complete(const FeedDetail(item: _note, body: '正文'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved XHS copy cannot mark the initial platform state saved', (
    WidgetTester tester,
  ) async {
    final pending = Completer<FeedDetail>();
    controller.savedCopy = true;
    controller.onDetail = (_) => pending.future;
    await _showDetail(tester, controller);
    expect(find.byIcon(Icons.bookmark), findsNothing);
    pending.complete(const FeedDetail(item: _note, body: '正文'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark), findsNothing);
  });

  testWidgets('refresh discards an earlier in-flight comment page', (
    WidgetTester tester,
  ) async {
    final oldPage = Completer<FeedDetail>();
    var firstPageRequests = 0;
    controller.onDetail = (String cursor) async {
      if (cursor.isNotEmpty) return oldPage.future;
      firstPageRequests++;
      return FeedDetail(
        item: _note,
        body: '正文',
        comments: <FeedComment>[
          _comment(firstPageRequests == 1 ? '原来的评论' : '刷新后的评论'),
        ],
        hasMore: firstPageRequests == 1,
        nextCursor: firstPageRequests == 1 ? 'page-2' : '',
      );
    };
    await _showDetail(tester, controller);
    await tester.tap(find.text('加载更多回复'));
    await tester.pump();
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    oldPage.complete(
      FeedDetail(
        item: _note,
        body: '正文',
        comments: <FeedComment>[_comment('过时分页评论')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('刷新后的评论', findRichText: true), findsOneWidget);
    expect(find.text('过时分页评论', findRichText: true), findsNothing);
    expect(find.text('加载更多回复'), findsNothing);
  });

  testWidgets('comment paging failure pauses automatic requests until retry', (
    WidgetTester tester,
  ) async {
    var pageRequests = 0;
    controller.onDetail = (String cursor) async {
      if (cursor.isEmpty) {
        return FeedDetail(
          item: _note,
          body: '正文',
          comments: <FeedComment>[_comment('首条评论')],
          hasMore: true,
          nextCursor: 'page-2',
        );
      }
      pageRequests++;
      if (pageRequests == 1) throw StateError('offline');
      return FeedDetail(
        item: _note,
        body: '正文',
        comments: <FeedComment>[_comment('重试得到的评论')],
      );
    };
    await _showDetail(tester, controller);
    await tester.tap(find.text('加载更多回复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('加载更多回复失败'), findsOneWidget);

    tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!
        .jumpTo(10);
    await tester.pumpAndSettle();
    expect(pageRequests, 1);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(pageRequests, 2);
    expect(find.text('重试得到的评论', findRichText: true), findsOneWidget);
  });
}
