import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/content_filters.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/home_screen.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/relationship_actions.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Author author(SourceId source, [String id = 'same-id']) => Author(
  ref: ProfileRef(source: source, id: id),
  id: id,
  name: '同名作者',
);
FeedItem note(Author author, [String id = 'note']) => FeedItem(
  ref: ContentRef(source: author.ref.source, id: id),
  title: '主题',
  author: author,
  stats: const ItemStats(),
);
FeedComment comment(
  Author author,
  String id, [
  List<FeedComment> replies = const [],
]) => FeedComment(
  ref: ContentRef(source: author.ref.source, id: id),
  author: author,
  body: '评论',
  replies: replies,
);

class _Xhs implements XhsWebSource {
  Completer<FeedPage>? pending;
  Completer<void>? followResponse;
  int followWrites = 0;
  @override
  Set<SourceCapability> get capabilities => {SourceCapability.follow};
  @override
  Future<void> follow(ProfileRef profile, bool value) async {
    followWrites++;
    await followResponse?.future;
  }

  @override
  SourceId get id => SourceId.xhs;
  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) async =>
      pending == null ? const FeedPage(items: []) : pending!.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tieba implements TiebaSource {
  @override
  SourceId get id => SourceId.tieba;
  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) async =>
      const FeedPage(items: []);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingSettings extends LocalSettings {
  _FailingSettings(super.preferences);
  @override
  Future<void> setAuthorBlocked(Author author, bool value) async =>
      throw StateError('disk full');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsync prefs;
  late LocalSettings settings;
  late _Xhs xhs;
  late MixsocialController controller;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    prefs = SharedPreferencesAsync();
    settings = LocalSettings(prefs);
    xhs = _Xhs();
    controller = MixsocialController(
      xhs: xhs,
      tieba: _Tieba(),
      settings: settings,
    );
  });
  tearDown(() => controller.dispose());

  testWidgets(
    'card menu follows only after confirmation and can cancel locally blocking',
    (tester) async {
      final post = note(author(SourceId.xhs));
      controller.items = [post];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: SizedBox(
                  width: 180,
                  child: MasonryFeedCard(
                    item: post,
                    onTap: () {},
                    onAuthorActions: () =>
                        showAuthorActions(context, controller, post.author),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('关注与屏蔽作者'));
      await tester.pumpAndSettle();
      expect(find.text('关注作者'), findsOneWidget);
      expect(find.text('仅在本机隐藏内容'), findsOneWidget);
      await tester.tap(find.text('屏蔽作者'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.isAuthorBlocked(post.author.ref), isFalse);
      expect(xhs.followWrites, 0);
      await tester.tap(find.byTooltip('关注与屏蔽作者'));
      await tester.pumpAndSettle();
      xhs.followResponse = Completer<void>();
      await tester.tap(find.text('关注作者'));
      await tester.pumpAndSettle();
      expect(xhs.followWrites, 1);
      expect(controller.isFollowing(post.author.ref), isFalse);
      expect(find.text('已关注'), findsNothing);
      xhs.followResponse!.complete();
      await tester.pumpAndSettle();
      expect(controller.isFollowing(post.author.ref), isTrue);
      expect(find.text('已关注'), findsOneWidget);
      await tester.tap(find.byTooltip('关注与屏蔽作者'));
      await tester.pumpAndSettle();
      expect(find.text('取消关注作者'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('blocking is source-scoped and survives controller restart', () async {
    final blocked = author(SourceId.xhs);
    final sameName = author(SourceId.xhs, 'different-id');
    final otherSite = author(SourceId.zhihu);
    controller.items = [note(blocked), note(sameName), note(otherSite)];
    await controller.setAuthorBlocked(blocked, true);
    expect(controller.items.map((item) => item.author.ref.key), [
      sameName.ref.key,
      otherSite.ref.key,
    ]);
    final restored = MixsocialController(
      xhs: xhs,
      tieba: _Tieba(),
      settings: LocalSettings(prefs),
    );
    addTearDown(restored.dispose);
    await restored.reloadLocalPreferences();
    expect(restored.isAuthorBlocked(blocked.ref), isTrue);
    expect(
      restored
          .prepareItems([note(blocked), note(otherSite)])
          .single
          .author
          .ref
          .key,
      otherSite.ref.key,
    );
    await restored.setAuthorBlocked(blocked, false);
    expect(await settings.blockedAuthors(), isEmpty);
    expect(restored.prepareItems([note(blocked)]), hasLength(1));
  });

  test(
    'filters root comments and nested replies without mutating source data',
    () async {
      final blocked = author(SourceId.tieba);
      final allowed = author(SourceId.tieba, 'allowed');
      final raw = [
        comment(blocked, 'root'),
        comment(allowed, 'good', [
          comment(blocked, 'hidden-reply'),
          comment(allowed, 'kept-reply', [comment(blocked, 'deep-reply')]),
        ]),
      ];
      await controller.setAuthorBlocked(blocked, true);
      final visible = controller.prepareComments(raw);
      expect(visible.single.ref.id, 'good');
      expect(visible.single.replies.single.ref.id, 'kept-reply');
      expect(visible.single.replies.single.replies, isEmpty);
      expect(raw, hasLength(2));
      expect(raw.last.replies, hasLength(2));
    },
  );

  test(
    'a response arriving after blocking is filtered before display',
    () async {
      final blocked = author(SourceId.xhs);
      xhs.pending = Completer<FeedPage>();
      controller.source = SourceId.xhs;
      final loading = controller.refresh(clearItems: true);
      await controller.setAuthorBlocked(blocked, true);
      xhs.pending!.complete(FeedPage(items: [note(blocked)]));
      await loading;
      expect(controller.items, isEmpty);
    },
  );

  test(
    'parallel local block writes preserve both rules and latest name',
    () async {
      final first = author(SourceId.xhs);
      final second = author(SourceId.tieba);
      await Future.wait([
        settings.setAuthorBlocked(first, true),
        settings.setAuthorBlocked(second, true),
      ]);
      expect(
        (await settings.blockedAuthors())
            .map((author) => author.ref.key)
            .toSet(),
        {first.ref.key, second.ref.key},
      );
      await settings.setAuthorBlocked(first.copyWith(name: '新名字'), true);
      expect(await settings.blockedAuthors(), hasLength(2));
      expect((await settings.blockedAuthors()).last.name, '新名字');
      await settings.setAuthorBlocked(second, false);
      expect((await settings.blockedAuthors()).single.ref.key, first.ref.key);
    },
  );

  test(
    'failed storage does not hide authors or report a stored rule',
    () async {
      final failed = MixsocialController(
        xhs: xhs,
        tieba: _Tieba(),
        settings: _FailingSettings(prefs),
      );
      addTearDown(failed.dispose);
      final blocked = author(SourceId.xhs);
      failed.items = [note(blocked)];
      await expectLater(
        failed.setAuthorBlocked(blocked, true),
        throwsStateError,
      );
      expect(failed.items, hasLength(1));
      expect(failed.isAuthorBlocked(blocked.ref), isFalse);
    },
  );

  test(
    'missing and anonymous identities never group unrelated authors',
    () async {
      for (final id in ['', '0', '00000000000000000000000000000000']) {
        final anonymous = author(SourceId.zhihu, id);
        expect(anonymous.ref.isIdentifiable, isFalse);
        await expectLater(
          settings.setAuthorBlocked(anonymous, true),
          throwsArgumentError,
        );
        expect(
          ContentFilters(
            blockedProfiles: {anonymous.ref.key},
          ).blocks(note(anonymous)),
          isFalse,
        );
      }
      await expectLater(
        settings.setAuthorBlocked(author(SourceId.all), true),
        throwsArgumentError,
      );
      expect(await settings.blockedAuthors(), isEmpty);
    },
  );
}
