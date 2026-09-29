import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/home_screen.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/profile_screen.dart';
import 'package:mixsocial_mobile/src/search_history.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _XhsSource implements XhsWebSource {
  final queries = <String>[];
  bool failSearch = false;

  @override
  SourceId get id => SourceId.xhs;

  @override
  XhsSearchFilters get searchFilters => const XhsSearchFilters();

  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<FeedPage> search(String query, {String cursor = ''}) async {
    queries.add(query);
    if (failSearch) throw StateError('offline');
    return const FeedPage();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TiebaSource implements TiebaSource {
  final queries = <String>[];

  @override
  Set<SourceCapability> get capabilities => const <SourceCapability>{};

  @override
  SourceId get id => SourceId.tieba;

  @override
  Future<bool> hasCredential() async => false;

  @override
  Future<FeedPage> search(String query, {String cursor = ''}) async {
    queries.add(query);
    return const FeedPage();
  }

  @override
  Future<ProfilePage> profile(
    ProfileRef profile, {
    ProfileSection section = ProfileSection.notes,
    String cursor = '',
  }) async => ProfilePage(ref: profile, name: '贴吧作者');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedHistory extends SearchHistoryStore {
  final result = Completer<List<String>>();

  @override
  Future<List<String>> add(SourceId source, String value) => result.future;
}

void main() {
  late _XhsSource xhs;
  late _TiebaSource tieba;
  late MixsocialController controller;
  late SearchHistoryStore history;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    xhs = _XhsSource();
    tieba = _TiebaSource();
    controller = MixsocialController(
      xhs: xhs,
      tieba: tieba,
      settings: LocalSettings(SharedPreferencesAsync()),
    )..source = SourceId.xhs;
    history = SearchHistoryStore();
  });

  tearDown(() => controller.dispose());

  testWidgets('Tieba feed author opens the supported profile page', (
    tester,
  ) async {
    controller
      ..source = SourceId.tieba
      ..layout = FeedLayout.list
      ..items = <FeedItem>[
        FeedItem(
          ref: const ContentRef(source: SourceId.tieba, id: '123'),
          title: '贴吧主题',
          author: const Author(
            ref: ProfileRef(source: SourceId.tieba, id: '42'),
            id: '42',
            name: '贴吧作者',
          ),
          stats: const ItemStats(),
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('贴吧作者'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);
  });

  Future<void> openSearch(
    WidgetTester tester, {
    SearchHistoryStore? store,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          controller: controller,
          searchHistoryStore: store ?? history,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
  }

  testWidgets('tap, delete and clear history keep platform records separate', (
    tester,
  ) async {
    await history.add(SourceId.xhs, '旅行');
    await history.add(SourceId.xhs, 'Flutter');
    await history.add(SourceId.tieba, '贴吧专属');
    await openSearch(tester);

    await tester.tap(find.text('Flutter'));
    await tester.pumpAndSettle();
    expect(xhs.queries, <String>['Flutter']);
    expect(tieba.queries, isEmpty);
    expect(
      tester
          .widget<SearchBar>(find.byKey(const Key('feed-search-field')))
          .controller!
          .text,
      'Flutter',
    );

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(xhs.queries, <String>['Flutter']);
    await tester.tap(find.byTooltip('删除搜索记录：Flutter'));
    await tester.pumpAndSettle();
    expect(await history.read(SourceId.xhs), <String>['旅行']);
    await tester.tap(find.byKey(const Key('clear-search-history')));
    await tester.pumpAndSettle();
    expect(await history.read(SourceId.xhs), isEmpty);

    await tester.tap(find.text('贴吧'));
    await tester.pumpAndSettle();
    expect(find.text('贴吧专属'), findsOneWidget);
    expect(tieba.queries, isEmpty);
  });

  testWidgets('empty input does not search and failed searches enter history', (
    tester,
  ) async {
    await openSearch(tester);
    await tester.enterText(find.byType(SearchBar), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(xhs.queries, isEmpty);
    expect(await history.read(SourceId.xhs), isEmpty);

    xhs.failSearch = true;
    await tester.enterText(find.byType(SearchBar), '  暂时离线  ');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(SearchBar),
        matching: find.byTooltip('搜索'),
      ),
    );
    await tester.pumpAndSettle();
    expect(xhs.queries, <String>['暂时离线']);
    expect(await history.read(SourceId.xhs), <String>['暂时离线']);
    expect(controller.error, contains('网络暂时不可用'));
  });

  testWidgets('slow or failed history writes never delay online search', (
    tester,
  ) async {
    final delayed = _DelayedHistory();
    await openSearch(tester, store: delayed);
    await tester.enterText(find.byType(SearchBar), '立即搜索');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(delayed.result.isCompleted, isFalse);
    expect(xhs.queries, <String>['立即搜索']);

    delayed.result.completeError(StateError('disk full'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(controller.searchQuery, '立即搜索');
  });

  testWidgets('a late history write stays with its original source', (
    tester,
  ) async {
    await history.add(SourceId.tieba, '贴吧专属');
    final delayed = _DelayedHistory();
    await openSearch(tester, store: delayed);
    await tester.enterText(find.byType(SearchBar), '小红书专属');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('贴吧'));
    await tester.pumpAndSettle();

    delayed.result.complete(<String>['小红书专属']);
    await tester.pumpAndSettle();
    expect(find.text('贴吧专属'), findsOneWidget);
    expect(find.text('小红书专属'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing search ignores unfinished history writes', (
    tester,
  ) async {
    final delayed = _DelayedHistory();
    await openSearch(tester, store: delayed);
    await tester.enterText(find.byType(SearchBar), '稍后完成');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    delayed.result.complete(<String>['稍后完成']);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'topic navigation records the query under the destination source',
    (tester) async {
      await openSearch(tester);
      controller.requestSearchNavigation(SourceId.tieba, '#Flutter');
      await tester.pumpAndSettle();

      expect(tieba.queries, <String>['Flutter']);
      expect(xhs.queries, isEmpty);
      expect(await history.read(SourceId.tieba), <String>['Flutter']);
      expect(await history.read(SourceId.xhs), isEmpty);
    },
  );
}
