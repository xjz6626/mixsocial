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

const _profile = ProfileRef(source: SourceId.xhs, id: 'author');
const _author = Author(ref: _profile, id: 'author', name: '作者');
const _note = FeedItem(
  ref: ContentRef(source: SourceId.xhs, id: 'note'),
  title: '笔记',
  author: _author,
  stats: ItemStats(),
);

class _XhsSource implements XhsWebSource {
  Future<void> Function(bool)? onFollow;
  int feedRequests = 0;

  @override
  Future<void> follow(ProfileRef profile, bool value) async {
    await onFollow?.call(value);
  }

  @override
  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''}) async {
    feedRequests++;
    throw StateError('feed must not be navigated after following');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TiebaSource implements TiebaSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends LocalSettings {
  _Settings() : super(SharedPreferencesAsync());
  bool failWrites = false;

  @override
  Future<void> setFollowing(ProfileRef profile, bool value) async {
    if (failWrites) throw StateError('disk full');
    await super.setFollowing(profile, value);
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
    'following updates only after platform confirmation, without a feed reload',
    () async {
      final response = Completer<void>();
      xhs.onFollow = (_) => response.future;
      final action = controller.follow(_profile, true);
      expect(controller.isFollowing(_profile), isFalse);
      expect(await settings.followingProfiles(), isEmpty);
      response.complete();
      expect(await action, isNull);
      expect(controller.isFollowing(_profile), isTrue);
      expect(controller.items.single.author.following, isTrue);
      expect(await settings.followingProfiles(), <String>{_profile.key});
      expect(xhs.feedRequests, 0);
    },
  );

  test(
    'platform rejection preserves confirmed relationship and local data',
    () async {
      await controller.follow(_profile, true);
      xhs.onFollow = (_) async => throw StateError('rejected');
      await expectLater(controller.follow(_profile, false), throwsStateError);
      expect(controller.isFollowing(_profile), isTrue);
      expect(controller.items.single.author.following, isTrue);
      expect(await settings.followingProfiles(), <String>{_profile.key});
    },
  );

  test(
    'confirmed unfollow overrides stale author and profile snapshots',
    () async {
      await controller.follow(_profile, true);
      await controller.follow(_profile, false);
      expect(
        controller.isFollowing(_profile, fallback: true, observed: true),
        isFalse,
      );
      expect(controller.items.single.author.following, isFalse);
      expect(await settings.followingProfiles(), isEmpty);
    },
  );

  test(
    'disk failure reports a warning but keeps platform-confirmed state',
    () async {
      settings.failWrites = true;
      expect(
        await controller.follow(_profile, true),
        contains('已关注，但本地记录保存失败'),
      );
      expect(controller.isFollowing(_profile), isTrue);
      expect(controller.items.single.author.following, isTrue);
      expect(
        await controller.follow(_profile, false),
        contains('已取消关注，但本地记录保存失败'),
      );
      expect(controller.isFollowing(_profile, fallback: true), isFalse);
    },
  );

  test('observed profile state distinguishes false from an unknown value', () {
    expect(
      controller.isFollowing(_profile, fallback: true, observed: false),
      isFalse,
    );
    expect(controller.isFollowing(_profile, fallback: true), isTrue);
    expect(controller.isFollowing(_profile, observed: true), isTrue);
    expect(ProfilePage.fromJson(<String, Object?>{}).following, isNull);
    expect(
      ProfilePage.fromJson(<String, Object?>{'following': false}).following,
      isFalse,
    );
    expect(
      ProfilePage.fromJson(<String, Object?>{'following': 'false'}).following,
      isNull,
    );
  });

  test('parallel local relationship writes do not erase one another', () async {
    const second = ProfileRef(source: SourceId.xhs, id: 'second');
    await Future.wait<void>(<Future<void>>[
      settings.setFollowing(_profile, true),
      settings.setFollowing(second, true),
    ]);
    expect(await settings.followingProfiles(), <String>{
      _profile.key,
      second.key,
    });
    await Future.wait<void>(<Future<void>>[
      settings.setFollowing(_profile, false),
      settings.setFollowing(second, false),
    ]);
    expect(await settings.followingProfiles(), isEmpty);
  });
}
