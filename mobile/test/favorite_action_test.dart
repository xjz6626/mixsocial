import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _note = FeedItem(
  ref: ContentRef(source: SourceId.xhs, id: 'note'),
  title: 'note',
  author: Author(
    ref: ProfileRef(source: SourceId.xhs, id: 'author'),
    id: 'author',
    name: 'author',
  ),
  stats: ItemStats(favorites: 7),
);

class _XhsSource implements XhsWebSource {
  Future<void> Function(bool)? onFavorite;

  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{
    SourceCapability.favorite,
  };

  @override
  Future<void> favorite(ContentRef ref, bool value) async {
    await onFavorite?.call(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TiebaSource implements TiebaSource {
  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends LocalSettings {
  _Settings() : super(SharedPreferencesAsync());

  bool failWrites = false;

  @override
  Future<void> setSaved(FeedItem item, bool value) async {
    if (failWrites) throw StateError('disk full');
    await super.setSaved(item, value);
  }
}

void main() {
  late _XhsSource xhs;
  late _Settings settings;
  late MixsocialController controller;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    xhs = _XhsSource();
    settings = _Settings();
    controller = MixsocialController(
      xhs: xhs,
      tieba: _TiebaSource(),
      settings: settings,
    )..items = <FeedItem>[_note];
  });

  tearDown(() => controller.dispose());

  test(
    'failed platform favorite leaves local state and count unchanged',
    () async {
      xhs.onFavorite = (_) async => throw StateError('login required');

      await expectLater(controller.favorite(_note, true), throwsStateError);

      expect(await settings.savedItems(), isEmpty);
      expect(controller.isSaved(_note), isFalse);
      expect(controller.items.single.favorited, isFalse);
      expect(controller.items.single.stats.favorites, 7);
    },
  );

  test('local favorite is stored only after the platform confirms', () async {
    xhs.onFavorite = (value) async {
      expect(value, isTrue);
      expect(await settings.savedItems(), isEmpty);
      expect(controller.items.single.favorited, isFalse);
    };

    expect(await controller.favorite(_note, true), isNull);
    expect(controller.items.single.favorited, isTrue);
    expect(controller.items.single.stats.favorites, 8);
    expect(controller.isSaved(_note), isTrue);
    expect((await settings.savedItems()).single.key, _note.key);
  });

  test(
    'failed cancellation retains both saved copy and platform state',
    () async {
      await controller.favorite(_note, true);
      xhs.onFavorite = (_) async => throw StateError('unavailable');

      await expectLater(controller.favorite(_note, false), throwsStateError);

      expect(controller.items.single.favorited, isTrue);
      expect(controller.items.single.stats.favorites, 8);
      expect(controller.isSaved(_note), isTrue);
      expect(await settings.savedItems(), hasLength(1));
    },
  );

  test(
    'local write failure preserves confirmed platform success with a warning',
    () async {
      settings.failWrites = true;

      final warning = await controller.favorite(_note, true);

      expect(warning, contains('本地副本保存失败'));
      expect(controller.items.single.favorited, isTrue);
      expect(controller.items.single.stats.favorites, 8);
      expect(controller.isSaved(_note), isFalse);
    },
  );

  test(
    'saved copy does not override a fresh Xiaohongshu platform state',
    () async {
      await controller.favorite(_note, true);

      expect(
        controller.prepareItems(<FeedItem>[_note]).single.favorited,
        isFalse,
      );
      expect(controller.isSaved(_note), isTrue);
    },
  );

  test('Tieba favorites remain local and propagate storage failure', () async {
    final thread = FeedItem(
      ref: const ContentRef(source: SourceId.tieba, id: 'thread'),
      title: 'thread',
      author: _note.author,
      stats: _note.stats,
    );
    controller.items = <FeedItem>[thread];
    settings.failWrites = true;
    await expectLater(controller.favorite(thread, true), throwsStateError);
    expect(controller.items.single.favorited, isFalse);

    settings.failWrites = false;
    expect(await controller.favorite(thread, true), isNull);
    expect(controller.isSaved(thread), isTrue);
    expect(
      controller.prepareItems(<FeedItem>[thread]).single.favorited,
      isTrue,
    );
  });

  test(
    'local library edits never call the platform or change its state',
    () async {
      xhs.onFavorite = (_) async =>
          fail('local management called the platform');
      controller.items = <FeedItem>[_note.copyWith(favorited: true)];

      await controller.setLocalSaved(_note, true);
      expect(controller.isSaved(_note), isTrue);
      await controller.setLocalSaved(_note, false);

      expect(await settings.savedItems(), isEmpty);
      expect(controller.isSaved(_note), isFalse);
      expect(controller.items.single.favorited, isTrue);
      expect(controller.items.single.stats.favorites, 7);
    },
  );

  test(
    'failed local removal preserves the saved copy and memory state',
    () async {
      await controller.setLocalSaved(_note, true);
      settings.failWrites = true;

      await expectLater(
        controller.setLocalSaved(_note, false),
        throwsStateError,
      );

      expect(controller.isSaved(_note), isTrue);
      expect(await settings.savedItems(), hasLength(1));
    },
  );
}
