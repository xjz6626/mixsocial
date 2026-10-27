import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:mixsocial_mobile/src/home_screen.dart';
import 'package:mixsocial_mobile/src/zhihu_source.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _XhsSource implements XhsWebSource {
  Completer<FeedPage>? nextBrowse;
  @override
  void setSearchFilters(XhsSearchFilters value) {}
  @override
  Future<FeedPage> search(String query, {String cursor = ''}) =>
      browse(FeedChannel.recommend, cursor: cursor);
  final cursors = <String>[];

  @override
  SourceId get id => SourceId.xhs;

  @override
  XhsSearchFilters get searchFilters => const XhsSearchFilters();

  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) {
    cursors.add(cursor);
    return nextBrowse!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TiebaSource implements TiebaSource {
  Completer<FeedPage>? nextBrowse;

  @override
  SourceId get id => SourceId.tieba;

  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) =>
      nextBrowse!.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ZhihuSource implements ZhihuSource {
  final nextBrowse = Completer<FeedPage>();
  @override
  bool get enabled => true;
  @override
  SourceId get id => SourceId.zhihu;
  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) =>
      nextBrowse.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FeedItem _item(SourceId source, String id) => FeedItem(
  ref: ContentRef(source: source, id: id),
  title: id,
  author: Author(
    ref: ProfileRef(source: source, id: 'author-$id'),
    id: 'author-$id',
    name: '作者',
  ),
  stats: const ItemStats(),
);

void main() {
  late _XhsSource xhs;
  late _TiebaSource tieba;
  late LocalSettings settings;
  late MixsocialController controller;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    xhs = _XhsSource();
    tieba = _TiebaSource();
    settings = LocalSettings(SharedPreferencesAsync());
    controller = MixsocialController(
      xhs: xhs,
      tieba: tieba,
      settings: settings,
    );
  });

  tearDown(() => controller.dispose());

  test(
    'mixed refresh waits for all three sources and interleaves regardless of completion order',
    () async {
      final zhihu = _ZhihuSource();
      controller.dispose();
      controller = MixsocialController(
        xhs: xhs,
        tieba: tieba,
        zhihu: zhihu,
        settings: settings,
      );
      xhs.nextBrowse = Completer<FeedPage>()
        ..complete(
          FeedPage(
            items: [_item(SourceId.xhs, 'x1'), _item(SourceId.xhs, 'x2')],
          ),
        );
      tieba.nextBrowse = Completer<FeedPage>();
      final refresh = controller.manualRefresh();
      await Future<void>.delayed(Duration.zero);
      expect(controller.items, isEmpty);
      tieba.nextBrowse!.complete(
        FeedPage(
          items: [_item(SourceId.tieba, 't1'), _item(SourceId.tieba, 't2')],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.items, isEmpty);
      await controller.loadMore();
      expect(xhs.cursors, ['']);
      zhihu.nextBrowse.complete(
        FeedPage(
          items: [_item(SourceId.zhihu, 'z1'), _item(SourceId.zhihu, 'z2')],
        ),
      );
      await refresh;
      expect(controller.items.map((item) => item.ref.id), [
        't1',
        'x1',
        'z1',
        't2',
        'x2',
        'z2',
      ]);
      expect(controller.loading, false);
    },
  );

  testWidgets('source status stays in one compact row without large chips', (
    tester,
  ) async {
    controller.sourceLoading.add(SourceId.xhs);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: FeedSourceStatusBar(controller: controller),
          ),
        ),
      ),
    );
    expect(find.byType(ActionChip), findsNothing);
    expect(
      tester.getSize(find.byType(FeedSourceStatusBar)).height,
      lessThanOrEqualTo(36),
    );
    expect(find.text('小红书 加载中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual refresh releases ready sources at 2 seconds and ignores a late response',
    (tester) async {
      final late = Completer<FeedPage>();
      xhs.nextBrowse = Completer<FeedPage>()
        ..complete(FeedPage(items: [_item(SourceId.xhs, 'ready')]));
      tieba.nextBrowse = late;
      final refresh = controller.manualRefresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1999));
      expect(controller.items, isEmpty);
      expect(controller.loading, true);
      await tester.pump(const Duration(milliseconds: 1));
      await refresh;
      expect(controller.loading, false);
      expect(controller.items.single.ref.id, 'ready');
      expect(controller.sourceErrors[SourceId.tieba], contains('超时'));
      late.complete(FeedPage(items: [_item(SourceId.tieba, 'late')]));
      await tester.pump();
      expect(controller.items.single.ref.id, 'ready');
      tieba.nextBrowse = Completer<FeedPage>()
        ..complete(FeedPage(items: [_item(SourceId.tieba, 'retry')]));
      await controller.retrySource(SourceId.tieba);
      expect(controller.items.map((item) => item.ref.id), ['ready', 'retry']);
      expect(controller.sourceErrors, isEmpty);
    },
  );

  testWidgets(
    'initial load allows 4 seconds and returns immediately when all sources finish',
    (tester) async {
      xhs.nextBrowse = Completer<FeedPage>();
      tieba.nextBrowse = Completer<FeedPage>()
        ..complete(FeedPage(items: [_item(SourceId.tieba, 'ready')]));
      final refresh = controller.refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3650));
      expect(controller.items, isEmpty);
      xhs.nextBrowse!.complete(FeedPage(items: [_item(SourceId.xhs, 'ready')]));
      await tester.pump();
      await refresh;
      expect(controller.items, hasLength(2));
      expect(controller.loading, false);
      expect(controller.sourceErrors, isEmpty);
    },
  );

  test(
    'duplicate page preserves explicit retry instead of declaring the end',
    () async {
      controller.source = SourceId.xhs;
      final page = FeedPage(
        items: [_item(SourceId.xhs, 'same')],
        nextCursor: 'more',
        hasMore: true,
      );
      xhs.nextBrowse = Completer<FeedPage>()..complete(page);
      await controller.refresh();
      xhs.nextBrowse = Completer<FeedPage>()..complete(page);
      await controller.loadMore();
      expect(controller.hasMore, true);
      expect(controller.paginationError, isNotNull);
      xhs.nextBrowse = Completer<FeedPage>()
        ..complete(FeedPage(items: [_item(SourceId.xhs, 'new')]));
      await controller.loadMore();
      expect(controller.items, hasLength(2));
      expect(controller.hasMore, false);
    },
  );

  test(
    'search and home restore independent snapshots without fetching again',
    () async {
      controller.source = SourceId.xhs;
      xhs.nextBrowse = Completer<FeedPage>()
        ..complete(FeedPage(items: [_item(SourceId.xhs, 'home')]));
      await controller.refresh();
      final homeKey = controller.sessionKey;
      controller.enterSearch();
      xhs.nextBrowse = Completer<FeedPage>()
        ..complete(FeedPage(items: [_item(SourceId.xhs, 'search')]));
      await controller.search('cats');
      final searchKey = controller.sessionKey;
      await controller.restoreFeed();
      expect(controller.sessionKey, homeKey);
      expect(controller.items.single.ref.id, 'home');
      controller.enterSearch();
      expect(controller.sessionKey, searchKey);
      expect(controller.items.single.ref.id, 'search');
      expect(xhs.cursors, hasLength(2));
    },
  );

  test(
    'account changes invalidate source and mixed cache, preserving local saved items',
    () async {
      final item = _item(SourceId.xhs, 'old-account');
      await settings.setSaved(item, true);
      await settings.saveFeedCache(SourceId.all, FeedChannel.recommend, [item]);
      await settings.saveFeedCache(SourceId.xhs, FeedChannel.recommend, [item]);
      await settings.setFollowing(item.author.ref, true);
      controller.items = [item];
      await controller.accountChanged(SourceId.xhs);
      expect(controller.items, isEmpty);
      expect(
        await settings.feedCache(SourceId.all, FeedChannel.recommend),
        isEmpty,
      );
      expect(await settings.followingProfiles(), isEmpty);
      expect(await settings.savedItems(), hasLength(1));
    },
  );

  for (final source in <SourceId>[SourceId.xhs, SourceId.tieba]) {
    test(
      'manual refresh clears the previous ${source.id} page immediately',
      () async {
        final result = Completer<FeedPage>();
        if (source == SourceId.xhs) {
          xhs.nextBrowse = result;
        } else {
          tieba.nextBrowse = result;
        }
        controller
          ..source = source
          ..items = <FeedItem>[_item(source, 'old')];

        final refresh = controller.manualRefresh();

        expect(controller.loading, isTrue);
        expect(controller.items, isEmpty);

        result.complete(FeedPage(items: <FeedItem>[_item(source, 'fresh')]));
        await refresh;

        expect(controller.items.single.ref.id, 'fresh');
        expect(controller.loading, isFalse);
      },
    );
  }

  test(
    'manual refresh failure does not restore the previous feed cache',
    () async {
      controller
        ..source = SourceId.xhs
        ..items = <FeedItem>[_item(SourceId.xhs, 'old')];
      await settings.saveFeedCache(
        SourceId.xhs,
        FeedChannel.recommend,
        <FeedItem>[_item(SourceId.xhs, 'cached')],
      );
      xhs.nextBrowse = Completer<FeedPage>()
        ..completeError(StateError('offline'));

      await controller.manualRefresh();

      expect(controller.items, isEmpty);
      expect(controller.error, contains('网络暂时不可用'));
    },
  );

  test(
    'a partial mixed refresh retains failed source items and cache',
    () async {
      final oldXhs = _item(SourceId.xhs, 'xhs-old');
      final oldTieba = _item(SourceId.tieba, 'tieba-old');
      controller.items = <FeedItem>[oldTieba, oldXhs];
      await settings.saveFeedCache(
        SourceId.all,
        FeedChannel.recommend,
        <FeedItem>[oldTieba, oldXhs],
      );
      xhs.nextBrowse = Completer<FeedPage>()
        ..completeError(StateError('request to private URL failed: offline'));
      tieba.nextBrowse = Completer<FeedPage>()
        ..complete(
          FeedPage(items: <FeedItem>[_item(SourceId.tieba, 'tieba-new')]),
        );

      await controller.refresh();

      expect(controller.items.map((item) => item.key).toSet(), {
        _item(SourceId.tieba, 'tieba-new').key,
        oldXhs.key,
      });
      expect(controller.sourceErrors[SourceId.xhs], contains('网络暂时不可用'));
      expect(controller.notices.join(), isNot(contains('private URL')));
      expect(
        (await settings.feedCache(
          SourceId.all,
          FeedChannel.recommend,
        )).map((item) => item.key).toList(),
        [oldTieba.key, oldXhs.key],
      );
    },
  );

  test('a failed mixed source keeps its previous pagination cursor', () async {
    xhs.nextBrowse = Completer<FeedPage>()
      ..complete(
        FeedPage(
          items: <FeedItem>[_item(SourceId.xhs, 'xhs-first')],
          nextCursor: 'xhs-next',
          hasMore: true,
        ),
      );
    tieba.nextBrowse = Completer<FeedPage>()
      ..complete(
        FeedPage(items: <FeedItem>[_item(SourceId.tieba, 'tieba-first')]),
      );
    await controller.refresh();

    xhs.nextBrowse = Completer<FeedPage>()
      ..completeError(StateError('offline'));
    tieba.nextBrowse = Completer<FeedPage>()
      ..complete(
        FeedPage(items: <FeedItem>[_item(SourceId.tieba, 'tieba-new')]),
      );
    await controller.refresh();
    expect(controller.hasMore, isTrue);

    xhs.nextBrowse = Completer<FeedPage>()
      ..complete(FeedPage(items: <FeedItem>[_item(SourceId.xhs, 'xhs-next')]));
    await controller.loadMore();
    expect(xhs.cursors.last, 'xhs-next');
    expect(controller.items.map((item) => item.ref.id), contains('xhs-next'));
  });
}
