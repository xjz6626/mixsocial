import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/login_screen.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/profile_screen.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _me = Author(
  ref: ProfileRef(source: SourceId.xhs, id: 'my-account'),
  id: 'my-account',
  name: '自己的主页',
);

class _XhsSource implements XhsWebSource {
  bool loggedIn = true;
  int accountCalls = 0;
  Future<Author> Function()? onCurrentProfile;
  final sections = <ProfileSection>[];

  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{
    SourceCapability.follow,
  };

  @override
  Future<bool> isLoggedIn() async => loggedIn;

  @override
  Future<Author> currentProfile() async {
    accountCalls++;
    return onCurrentProfile == null ? _me : await onCurrentProfile!();
  }

  @override
  Future<ProfilePage> profile(
    ProfileRef ref, {
    ProfileSection section = ProfileSection.notes,
    String cursor = '',
  }) async {
    sections.add(section);
    return ProfilePage(ref: _me.ref, name: _me.name);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TiebaSource implements TiebaSource {
  @override
  Future<bool> hasCredential() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _XhsSource xhs;
  late MixsocialController controller;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    xhs = _XhsSource();
    controller = MixsocialController(
      xhs: xhs,
      tieba: _TiebaSource(),
      settings: LocalSettings(SharedPreferencesAsync()),
    );
  });

  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: AccountScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('my XHS profile is only offered when login was detected', (
    tester,
  ) async {
    xhs.loggedIn = false;
    await open(tester);
    expect(find.byKey(const Key('xhs-current-profile')), findsNothing);
    expect(xhs.accountCalls, 0);
  });

  testWidgets('account screen exposes Zhihu login without claiming a session', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('知乎'), findsOneWidget);
    expect(find.byKey(const Key('zhihu-web-login')), findsOneWidget);
    expect(find.byKey(const Key('zhihu-import-cookie')), findsOneWidget);
    expect(find.byKey(const Key('zhihu-verify-login')), findsNothing);
  });

  testWidgets(
    'my profile reuses notes, platform favorites and likes without self-follow',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('xhs-current-profile')));
      await tester.pumpAndSettle();

      final profile = tester.widget<ProfileScreen>(find.byType(ProfileScreen));
      expect(profile.author.id, _me.id);
      expect(profile.isOwnProfile, isTrue);
      expect(find.text('关注'), findsNothing);
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('点赞'));
      await tester.pumpAndSettle();
      expect(xhs.sections, <ProfileSection>[
        ProfileSection.notes,
        ProfileSection.favorites,
        ProfileSection.liked,
      ]);
      expect(xhs.accountCalls, 1);
    },
  );

  testWidgets(
    'pending account reads cannot be submitted twice and errors can retry',
    (tester) async {
      final pending = Completer<Author>();
      xhs.onCurrentProfile = () => pending.future;
      await open(tester);
      await tester.tap(find.byKey(const Key('xhs-current-profile')));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('xhs-current-profile')),
            )
            .onPressed,
        isNull,
      );
      expect(xhs.accountCalls, 1);

      pending.completeError(StateError('请重新登录或完成验证'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请重新登录或完成验证'), findsOneWidget);
      expect(find.byType(ProfileScreen), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('xhs-current-profile')),
            )
            .onPressed,
        isNotNull,
      );
      xhs.onCurrentProfile = null;
      await tester.tap(find.byKey(const Key('xhs-current-profile')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(xhs.accountCalls, 2);
    },
  );
}
