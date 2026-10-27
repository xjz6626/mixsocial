import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/detail_screen.dart';
import 'package:mixsocial_mobile/src/forum_screen.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/reader_tools_screen.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:mixsocial_mobile/src/zhihu_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Author _author(SourceId source, [String id = '17']) => Author(
  ref: ProfileRef(source: source, id: id),
  id: id,
  name: '同名作者',
);

FeedItem _item(SourceId source, [String id = '17']) => FeedItem(
  ref: ContentRef(source: source, id: 'post-$id'),
  title: '${source.label}帖子',
  author: _author(source, id),
  stats: const ItemStats(),
);

class _Xhs implements XhsWebSource {
  @override
  SourceId get id => SourceId.xhs;
  @override
  Set<SourceCapability> get capabilities => {SourceCapability.follow};
  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) async =>
      FeedPage(items: [_item(SourceId.xhs)]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tieba implements TiebaSource {
  List<String> forums = [];
  bool authorFollowing = false;
  int authorWrites = 0;
  int forumWrites = 0;
  Future<void> Function()? onAuthorFollow;
  Future<bool> Function()? onAuthorState;
  Future<void> Function()? onForumFollow;
  bool failFollowing = false;
  Future<List<String>> Function()? onFollowing;
  int followingReads = 0;
  @override
  Set<SourceCapability> get capabilities => {SourceCapability.follow};
  @override
  Future<List<String>> followingForums() async {
    followingReads++;
    if (onFollowing != null) return onFollowing!();
    if (failFollowing) throw StateError('offline');
    return forums;
  }

  @override
  Future<FeedPage> forum(
    String forum, {
    String cursor = '',
    int sortType = 0,
  }) async => FeedPage(items: [_item(SourceId.tieba)]);
  @override
  Future<ProfilePage> profile(
    ProfileRef ref, {
    ProfileSection section = ProfileSection.notes,
    String cursor = '',
  }) async => ProfilePage(
    ref: ProfileRef(
      source: ref.source,
      id: ref.id,
      url: 'https://tieba.baidu.com/home/main?un=canonical-user',
    ),
    name: '同名作者',
    items: [],
  );
  @override
  Future<bool> following(ProfileRef profile) async =>
      onAuthorState == null ? authorFollowing : onAuthorState!();
  @override
  Future<void> follow(ProfileRef profile, bool value) async {
    authorWrites++;
    await onAuthorFollow?.call();
    authorFollowing = value;
  }

  @override
  Future<bool> forumFollowing(String forum) async =>
      (await followingForums()).contains(forum.toLowerCase());
  @override
  Future<void> followForum(String forum, bool value) async {
    forumWrites++;
    await onForumFollow?.call();
    value
        ? forums.add(forum.toLowerCase())
        : forums.remove(forum.toLowerCase());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Zhihu implements ZhihuSource {
  bool authorFollowing = false;
  int authorWrites = 0;
  Future<void> Function()? onAuthorFollow;
  @override
  bool get enabled => true;
  @override
  Set<SourceCapability> get capabilities => {SourceCapability.follow};
  @override
  Future<bool> following(ProfileRef profile) async => authorFollowing;
  @override
  Future<void> follow(ProfileRef profile, bool value) async {
    authorWrites++;
    await onAuthorFollow?.call();
    authorFollowing = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends MixsocialController {
  _Controller(LocalSettings settings, _Tieba tieba, _Zhihu zhihu)
    : super(xhs: _Xhs(), tieba: tieba, zhihu: zhihu, settings: settings);
  @override
  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) async => FeedDetail(item: _item(ref.source), body: '正文');
}

class _FailingSettings extends LocalSettings {
  _FailingSettings() : super(SharedPreferencesAsync());
  @override
  Future<void> setAuthorBlocked(Author author, bool value) async =>
      throw StateError('disk full');
}

void main() {
  late LocalSettings settings;
  late _Tieba tieba;
  late _Zhihu zhihu;
  late _Controller controller;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    settings = LocalSettings(SharedPreferencesAsync());
    tieba = _Tieba();
    zhihu = _Zhihu();
    controller = _Controller(settings, tieba, zhihu)..source = SourceId.xhs;
  });
  tearDown(() => controller.dispose());

  test(
    'author blocks cover all sources without matching names or IDs across sources',
    () async {
      final items = [
        for (final source in [SourceId.xhs, SourceId.tieba, SourceId.zhihu])
          _item(source),
      ];
      controller.items = items;
      for (final item in items) {
        await controller.setAuthorBlocked(item.author, true);
        expect(controller.isAuthorBlocked(item.author.ref), isTrue);
        expect(controller.prepareItems(items), isNot(contains(item)));
      }
      expect(controller.items, isEmpty);
      expect(controller.blockedAuthors, hasLength(3));
      expect(
        controller.prepareItems([_item(SourceId.xhs, 'other-id')]),
        hasLength(1),
      );
      final restored = _Controller(settings, tieba, zhihu)
        ..source = SourceId.xhs;
      addTearDown(restored.dispose);
      await restored.reloadLocalPreferences();
      expect(restored.prepareItems(items), isEmpty);
      await restored.setAuthorBlocked(items[1].author, false);
      expect(restored.prepareItems(items).map((item) => item.ref.source), [
        SourceId.tieba,
      ]);
    },
  );

  test(
    'blocking an author also removes nested comments without changing platform follows or stored copies',
    () async {
      final author = _author(SourceId.tieba);
      final post = _item(SourceId.tieba);
      await settings.setFollowing(author.ref, true);
      await settings.setSaved(post, true);
      await settings.addHistory(post);
      final blockedReply = FeedComment(
        ref: const ContentRef(source: SourceId.tieba, id: 'blocked'),
        author: author,
        body: '隐藏的回复',
      );
      final parent = FeedComment(
        ref: const ContentRef(source: SourceId.tieba, id: 'visible'),
        author: _author(SourceId.tieba, 'other'),
        body: '保留的回复',
        replies: [blockedReply],
      );
      await controller.setAuthorBlocked(author, true);
      expect(
        controller.prepareComments([blockedReply, parent]).single.replies,
        isEmpty,
      );
      expect(await controller.savedItems(), isEmpty);
      expect(await controller.historyItems(), isEmpty);
      expect(await settings.savedItems(), hasLength(1));
      expect(await settings.historyItems(), hasLength(1));
      expect(await settings.followingProfiles(), contains(author.ref.key));
      await controller.setAuthorBlocked(author, false);
      expect(await controller.savedItems(), hasLength(1));
      expect(controller.prepareComments([blockedReply, parent]), hasLength(2));
    },
  );

  test(
    'parallel filter changes survive restart and missing identities are rejected',
    () async {
      await Future.wait([
        settings.setAuthorBlocked(_author(SourceId.xhs), true),
        settings.setAuthorBlocked(_author(SourceId.tieba), true),
        settings.setAuthorBlocked(_author(SourceId.zhihu), true),
        settings.setForumBlocked('Golang吧', true),
        settings.setForumBlocked('Flutter吧', true),
      ]);
      expect(await settings.blockedAuthors(), hasLength(3));
      expect(await settings.blockedForums(), {'golang', 'flutter'});
      await expectLater(
        settings.setAuthorBlocked(_author(SourceId.xhs, ''), true),
        throwsArgumentError,
      );
      await expectLater(
        settings.setAuthorBlocked(_author(SourceId.xhs, '0'), true),
        throwsArgumentError,
      );
      expect(await settings.blockedAuthors(), hasLength(3));
    },
  );

  test(
    'a failed block write leaves visible content and block state unchanged',
    () async {
      final failing = _Controller(_FailingSettings(), tieba, zhihu)
        ..items = [_item(SourceId.xhs)];
      addTearDown(failing.dispose);
      await expectLater(
        failing.setAuthorBlocked(_author(SourceId.xhs), true),
        throwsStateError,
      );
      expect(failing.items, hasLength(1));
      expect(failing.isAuthorBlocked(_author(SourceId.xhs).ref), isFalse);
    },
  );

  for (final source in [SourceId.tieba, SourceId.zhihu]) {
    testWidgets(
      '${source.id} authors follow and unfollow inside the app after confirmation',
      (tester) async {
        final response = Completer<void>();
        if (source == SourceId.tieba) {
          tieba.onAuthorFollow = () => response.future;
        } else {
          zhihu.onAuthorFollow = () => response.future;
        }
        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              controller: controller,
              initialItem: _item(source),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('关注'));
        await tester.pump();
        expect(controller.isFollowing(_author(source).ref), isFalse);
        expect(await settings.followingProfiles(), isEmpty);
        expect(find.text('${source.label}作者关注管理'), findsNothing);
        response.complete();
        await tester.pumpAndSettle();
        expect(find.widgetWithText(OutlinedButton, '已关注'), findsOneWidget);
        expect(await settings.followingProfiles(), contains('${source.id}:17'));
        await tester.tap(find.widgetWithText(OutlinedButton, '已关注'));
        await tester.pumpAndSettle();
        expect(find.text('关注'), findsOneWidget);
        expect(await settings.followingProfiles(), isEmpty);
        expect(
          source == SourceId.tieba ? tieba.authorWrites : zhihu.authorWrites,
          2,
        );
      },
    );
  }

  testWidgets(
    'forum follow button confirms success and preserves state when cancellation fails',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ForumScreen(controller: controller, forum: 'Golang'),
        ),
      );
      await tester.pumpAndSettle();
      final response = Completer<void>();
      tieba.onForumFollow = () => response.future;
      await tester.tap(find.text('关注'));
      await tester.pump();
      expect(controller.confirmedForumFollowing('golang'), isFalse);
      expect(find.text('已关注'), findsNothing);
      response.complete();
      await tester.pumpAndSettle();
      expect(find.text('已关注'), findsOneWidget);
      tieba.onForumFollow = () async => throw StateError('rejected');
      await tester.tap(find.text('已关注'));
      await tester.pumpAndSettle();
      expect(find.text('已关注'), findsOneWidget);
      expect(controller.confirmedForumFollowing('golang'), isTrue);
      tieba.onForumFollow = null;
      await tester.tap(find.text('已关注'));
      await tester.pumpAndSettle();
      expect(find.text('关注'), findsOneWidget);
      expect(controller.confirmedForumFollowing('golang'), isFalse);
      expect(tieba.forumWrites, 3);
    },
  );

  testWidgets(
    'failed initial forum state can be retried without sending a write',
    (tester) async {
      tieba.failFollowing = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ForumScreen(controller: controller, forum: 'Golang'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('重试关注状态'), findsOneWidget);
      expect(tieba.forumWrites, 0);
      tieba.failFollowing = false;
      await tester.tap(find.text('重试关注状态'));
      await tester.pumpAndSettle();
      expect(find.text('关注'), findsOneWidget);
      expect(tieba.forumWrites, 0);
    },
  );

  testWidgets('blocked authors can be removed from content settings', (
    tester,
  ) async {
    // Construct the write queue in the widget test's fake-async zone, so all
    // preference callbacks advance with pump rather than a real event loop.
    controller.dispose();
    settings = LocalSettings(SharedPreferencesAsync());
    controller = _Controller(settings, tieba, zhihu)..source = SourceId.xhs;
    final blocking = controller.setAuthorBlocked(_author(SourceId.zhihu), true);
    await tester.pump();
    await blocking;
    await tester.pumpWidget(
      MaterialApp(home: ContentSettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    final remove = find.byTooltip('解除屏蔽作者');
    await tester.scrollUntilVisible(remove, 400);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(controller.blockedAuthors, isEmpty);
    expect(await settings.blockedAuthors(), isEmpty);
  });

  testWidgets(
    'a delayed forum lookup cannot overwrite a confirmed follow from another screen',
    (tester) async {
      final initial = Completer<List<String>>();
      tieba.onFollowing = () => initial.future;
      await tester.pumpWidget(
        MaterialApp(
          home: ForumScreen(controller: controller, forum: 'Golang'),
        ),
      );
      await tester.pumpAndSettle();
      await controller.followForum('golang', true);
      await tester.pumpAndSettle();
      initial.complete([]);
      await tester.pumpAndSettle();
      expect(find.text('已关注'), findsOneWidget);
      expect(controller.confirmedForumFollowing('golang'), isTrue);
    },
  );

  test(
    'late author state reads cannot overwrite a confirmed write or cross accounts',
    () async {
      final oldRead = Completer<bool>();
      tieba.onAuthorState = () => oldRead.future;
      final author = _author(SourceId.tieba).ref;
      final reading = controller.readFollowing(author);
      await controller.follow(author, true);
      oldRead.complete(false);
      expect(await reading, isTrue);
      expect(controller.isFollowing(author), isTrue);
      final previousAccount = Completer<bool>();
      tieba.onAuthorState = () => previousAccount.future;
      final late = controller.readFollowing(author);
      final rejected = expectLater(late, throwsStateError);
      await controller.accountChanged(SourceId.tieba);
      previousAccount.complete(true);
      await rejected;
      expect(controller.isFollowing(author), isFalse);
    },
  );

  test(
    'forum writes deduplicate normalized names and do not cross accounts',
    () async {
      final response = Completer<void>();
      tieba.onForumFollow = () => response.future;
      final writing = controller.followForum('Golang吧', true);
      final rejected = expectLater(writing, throwsStateError);
      await expectLater(
        controller.followForum('golang', true),
        throwsStateError,
      );
      expect(tieba.forumWrites, 1);
      await controller.accountChanged(SourceId.tieba);
      response.complete();
      await rejected;
      expect(controller.confirmedForumFollowing('golang'), isNull);
    },
  );

  test(
    'forum state reads started during a write cannot replace its result',
    () async {
      expect(await controller.forumFollowing('golang'), isFalse);
      final response = Completer<void>();
      tieba.onForumFollow = () => response.future;
      final writing = controller.followForum('golang', true);
      expect(await controller.forumFollowing('golang'), isFalse);
      expect(tieba.followingReads, 1);
      response.complete();
      await writing;
      expect(controller.confirmedForumFollowing('golang'), isTrue);
    },
  );
}
