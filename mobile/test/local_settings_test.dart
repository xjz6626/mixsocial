import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/design_system.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

FeedItem _item(int index) => FeedItem(
  ref: ContentRef(source: SourceId.tieba, id: 'thread-$index'),
  title: '主题 $index',
  author: Author(
    ref: ProfileRef(source: SourceId.tieba, id: 'author-$index'),
    id: 'author-$index',
    name: '作者 $index',
  ),
  stats: const ItemStats(),
  tags: const <String>['Flutter吧'],
);

void main() {
  late SharedPreferencesAsync preferences;
  late LocalSettings settings;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    preferences = SharedPreferencesAsync();
    settings = LocalSettings(preferences);
  });

  test('appearance and layouts persist with useful defaults', () async {
    expect(await settings.themePreference(), AppThemePreference.system);
    expect(await settings.layoutFor(SourceId.tieba), FeedLayout.list);
    expect(await settings.layoutFor(SourceId.all), FeedLayout.masonry);

    await settings.setThemePreference(AppThemePreference.dark);
    await settings.setLayout(SourceId.tieba, FeedLayout.masonry);

    final restored = LocalSettings(preferences);
    expect(await restored.themePreference(), AppThemePreference.dark);
    expect(await restored.layoutFor(SourceId.tieba), FeedLayout.masonry);

    await preferences.setString('appearance.theme', 'future-value');
    expect(await restored.themePreference(), AppThemePreference.system);
  });

  test('scroll positions reject invalid and negative values', () async {
    await settings.setScrollOffset(SourceId.all, 480.5);
    expect(await settings.scrollOffsetFor(SourceId.all), 480.5);

    await settings.setScrollOffset(SourceId.all, -12);
    expect(await settings.scrollOffsetFor(SourceId.all), 0);

    await preferences.setDouble('scroll.all', double.nan);
    expect(await settings.scrollOffsetFor(SourceId.all), 0);
  });

  test('filters normalize and persist values', () async {
    await settings.setForumBlocked(' Flutter吧 ', true);
    await settings.setForumBlocked('flutter', true);
    await settings.setKeywordBlocked('  广 告  ', true);
    await settings.setHideVideos(true);
    await settings.setHideMedia(true);

    expect(await settings.blockedForums(), <String>{'flutter'});
    expect(await settings.blockedKeywords(), <String>{'广 告'});
    expect(await settings.hideVideos(), isTrue);
    expect(await settings.hideMedia(), isTrue);
  });

  test(
    'feed cache round-trips, caps entries and tolerates corruption',
    () async {
      await settings.saveFeedCache(
        SourceId.tieba,
        FeedChannel.recommend,
        List<FeedItem>.generate(125, _item),
      );

      final cached = await settings.feedCache(
        SourceId.tieba,
        FeedChannel.recommend,
      );
      expect(cached, hasLength(120));
      expect(cached.first.key, 'tieba:thread-0');
      expect(cached.last.key, 'tieba:thread-119');

      await preferences.setString('cache.feed.tieba.recommend', '{broken');
      expect(
        await settings.feedCache(SourceId.tieba, FeedChannel.recommend),
        isEmpty,
      );
    },
  );

  test('history and saved items deduplicate and apply their limits', () async {
    for (var index = 0; index < 105; index++) {
      await settings.addHistory(_item(index));
    }
    await settings.addHistory(_item(100));

    final history = await settings.historyItems();
    expect(history, hasLength(100));
    expect(history.first.key, 'tieba:thread-100');
    expect(
      history.where((item) => item.key == history.first.key),
      hasLength(1),
    );

    final favorite = _item(7);
    await settings.setSaved(favorite, true);
    final saved = await settings.savedItems();
    expect(saved, hasLength(1));
    expect(saved.single.key, favorite.key);
    expect(saved.single.favorited, isTrue);

    await settings.setSaved(favorite, false);
    expect(await settings.savedItems(), isEmpty);
  });

  test('read later persists independently of favorites and history', () async {
    final item = _item(4);
    expect(await settings.isReadLater(item.key), isFalse);
    await settings.setSaved(item, true);
    await settings.addHistory(item);
    await settings.setReadLater(item, true);

    final restored = LocalSettings(preferences);
    expect(await restored.isReadLater(item.key), isTrue);
    expect((await restored.readLaterItems()).single.favorited, isFalse);

    await restored.setReadLater(item, false);
    expect(await restored.readLaterItems(), isEmpty);
    expect((await restored.savedItems()).single.key, item.key);
    expect((await restored.historyItems()).single.key, item.key);
  });

  test(
    'rapid read later writes keep all items and honor the last action',
    () async {
      final pending = <Future<void>>[
        for (var index = 0; index < 12; index++)
          settings.setReadLater(_item(index), true),
        settings.setReadLater(_item(3), false),
        settings.setReadLater(_item(3), true),
        settings.setReadLater(_item(4), false),
      ];
      // Reads wait for already queued writes, even without awaiting each tap.
      final items = await settings.readLaterItems();
      await Future.wait(pending);
      expect(items, hasLength(11));
      expect(items.first.key, _item(3).key);
      expect(items.map((item) => item.key).toSet(), hasLength(11));
      expect(await settings.isReadLater(_item(4).key), isFalse);
    },
  );

  test(
    'read later keeps the most recent 300 items and handles bad data',
    () async {
      for (var index = 0; index < 302; index++) {
        await settings.setReadLater(_item(index), true);
      }
      await settings.setReadLater(_item(8).copyWith(title: '更新标题'), true);
      final items = await settings.readLaterItems();
      expect(items, hasLength(300));
      expect(items.first.key, _item(8).key);
      expect(items.first.title, '更新标题');
      expect(await settings.isReadLater(_item(1).key), isFalse);
      expect(await settings.isReadLater(_item(2).key), isTrue);

      await preferences.setString('library.readLaterState.v1', '{broken');
      expect(await settings.readLaterItems(), isEmpty);
      await settings.setReadLater(_item(9), true);
      expect((await settings.readLaterItems()).single.key, _item(9).key);
    },
  );
}
