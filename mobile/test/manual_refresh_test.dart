import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
      expect(controller.notices.join(), contains('网络暂时不可用'));
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
