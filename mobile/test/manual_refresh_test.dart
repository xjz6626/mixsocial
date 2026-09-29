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

  @override
  SourceId get id => SourceId.xhs;

  @override
  XhsSearchFilters get searchFilters => const XhsSearchFilters();

  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) =>
      nextBrowse!.future;

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
      expect(controller.error, contains('offline'));
    },
  );
}
