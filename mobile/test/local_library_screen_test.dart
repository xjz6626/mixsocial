import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/library_filter.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/reader_tools_screen.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _note = FeedItem(
  ref: ContentRef(source: SourceId.xhs, id: 'note', token: 'hidden-token'),
  title: '秋天散步路线',
  summary: '公园与咖啡',
  author: Author(
    ref: ProfileRef(source: SourceId.xhs, id: 'author'),
    id: 'author',
    name: 'Alice',
  ),
  stats: ItemStats(),
);
const _thread = FeedItem(
  ref: ContentRef(source: SourceId.tieba, id: 'thread'),
  title: 'Flutter 布局讨论',
  author: Author(
    ref: ProfileRef(source: SourceId.tieba, id: 'bob'),
    id: 'bob',
    name: 'Bob',
  ),
  tags: <String>['Flutter吧'],
  stats: ItemStats(),
);

class _Xhs implements XhsWebSource {
  @override
  Future<void> favorite(ContentRef ref, bool value) async {
    fail('Local library must not send platform interactions');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tieba implements TiebaSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends LocalSettings {
  _Settings() : super(SharedPreferencesAsync());
  bool failWrites = false;
  bool failHistoryRead = false;
  Completer<void>? delayedRemoval;

  @override
  Future<List<FeedItem>> historyItems() async {
    if (failHistoryRead) throw StateError('history unavailable');
    return super.historyItems();
  }

  @override
  Future<void> setSaved(FeedItem item, bool value) async {
    if (!value && delayedRemoval != null) await delayedRemoval!.future;
    if (failWrites) throw StateError('storage unavailable');
    await super.setSaved(item, value);
  }
}

class _ReadLaterController extends MixsocialController {
  _ReadLaterController(LocalSettings settings)
    : super(xhs: _Xhs(), tieba: _Tieba(), settings: settings);

  final List<FeedItem> _queued = <FeedItem>[];

  @override
  Future<List<FeedItem>> readLaterItems() async => List<FeedItem>.of(_queued);

  @override
  Future<bool> isReadLater(FeedItem item) async =>
      _queued.any((entry) => entry.key == item.key);

  @override
  Future<void> setReadLater(FeedItem item, bool value) async {
    _queued.removeWhere((entry) => entry.key == item.key);
    if (value) _queued.add(item);
    notifyListeners();
  }
}

void main() {
  late _Settings settings;
  late MixsocialController controller;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    settings = _Settings();
    controller = MixsocialController(
      xhs: _Xhs(),
      tieba: _Tieba(),
      settings: settings,
    );
  });

  tearDown(() => controller.dispose());

  Future<void> showLibrary(WidgetTester tester, LocalLibraryKind kind) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LocalLibraryScreen(controller: controller, kind: kind),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('library search matches visible text literally and combines terms', () {
    expect(
      filterLibraryItems(<FeedItem>[_note, _thread], query: '公园 ALICE'),
      <FeedItem>[_note],
    );
    expect(
      filterLibraryItems(<FeedItem>[_note, _thread], query: 'Flutter吧 bob'),
      <FeedItem>[_thread],
    );
    expect(
      filterLibraryItems(<FeedItem>[_note], query: 'hidden-token'),
      isEmpty,
    );
    expect(filterLibraryItems(<FeedItem>[_note], query: '%'), isEmpty);
    expect(
      filterLibraryItems(<FeedItem>[_note, _thread], source: SourceId.tieba),
      <FeedItem>[_thread],
    );
  });

  testWidgets('local search and platform filters can be cleared', (
    tester,
  ) async {
    await controller.setLocalSaved(_note, true);
    await controller.setLocalSaved(_thread, true);
    await showLibrary(tester, LocalLibraryKind.saved);
    expect(find.byKey(const Key('library-item-xhs:note')), findsOneWidget);
    expect(find.byKey(const Key('library-item-tieba:thread')), findsOneWidget);

    await tester.tap(find.byKey(const Key('library-source-tieba')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-item-xhs:note')), findsNothing);
    await tester.enterText(find.byKey(const Key('library-search')), '公园');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的内容'), findsOneWidget);

    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-item-xhs:note')), findsOneWidget);
    expect(find.byKey(const Key('library-item-tieba:thread')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local removal can be undone without a platform request', (
    tester,
  ) async {
    await controller.setLocalSaved(_note, true);
    await showLibrary(tester, LocalLibraryKind.saved);

    await tester.tap(find.byKey(const Key('library-remove-xhs:note')));
    await tester.pumpAndSettle();
    expect(await settings.savedItems(), isEmpty);
    expect(find.byKey(const Key('library-item-xhs:note')), findsNothing);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect((await settings.savedItems()).single.key, _note.key);
    expect(find.byKey(const Key('library-item-xhs:note')), findsOneWidget);
  });

  testWidgets('failed removal keeps the item visible with an error', (
    tester,
  ) async {
    await controller.setLocalSaved(_note, true);
    await showLibrary(tester, LocalLibraryKind.saved);
    settings.failWrites = true;

    await tester.tap(find.byKey(const Key('library-remove-xhs:note')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-item-xhs:note')), findsOneWidget);
    expect(find.textContaining('本地内容更新失败'), findsOneWidget);
    expect(await settings.savedItems(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('read later queue supports local removal and undo', (
    tester,
  ) async {
    controller.dispose();
    controller = _ReadLaterController(settings);
    await controller.setReadLater(_note, true);
    await showLibrary(tester, LocalLibraryKind.readLater);
    expect(find.byKey(const Key('library-item-xhs:note')), findsOneWidget);

    await tester.tap(find.byKey(const Key('library-remove-xhs:note')));
    await tester.pumpAndSettle();
    expect(await controller.isReadLater(_note), isFalse);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(await controller.isReadLater(_note), isTrue);
    expect(await settings.savedItems(), isEmpty);
  });

  testWidgets(
    'undo waits for an in-flight removal instead of being discarded',
    (tester) async {
      await controller.setLocalSaved(_note, true);
      await controller.setLocalSaved(_thread, true);
      await showLibrary(tester, LocalLibraryKind.saved);
      await tester.tap(find.byKey(const Key('library-remove-xhs:note')));
      await tester.pumpAndSettle();

      final pending = Completer<void>();
      settings.delayedRemoval = pending;
      await tester.tap(find.byKey(const Key('library-remove-tieba:thread')));
      await tester.pump();
      await tester.tap(find.text('撤销'));
      await tester.pump();
      pending.complete();
      await tester.pumpAndSettle();

      expect((await settings.savedItems()).single.key, _note.key);
      expect(find.byKey(const Key('library-item-xhs:note')), findsOneWidget);
      expect(find.byKey(const Key('library-item-tieba:thread')), findsNothing);
    },
  );

  testWidgets('filters scroll with the list in a short keyboard viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await controller.setLocalSaved(_note, true);
    await showLibrary(tester, LocalLibraryKind.saved);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful clear dismisses an earlier history read error', (
    tester,
  ) async {
    await controller.recordHistory(_note);
    await showLibrary(tester, LocalLibraryKind.history);
    settings.failHistoryRead = true;
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('本地内容读取失败'), findsOneWidget);

    await tester.tap(find.byTooltip('清空历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('本地内容读取失败'), findsNothing);
    expect(find.text('还没有浏览历史内容'), findsOneWidget);
  });
}
