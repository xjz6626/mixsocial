import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/profile_screen.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _profile = ProfileRef(source: SourceId.xhs, id: 'author');
const _author = Author(ref: _profile, id: 'author', name: '作者');

FeedItem _note(String id) => FeedItem(
  ref: ContentRef(source: SourceId.xhs, id: id),
  title: id,
  author: _author,
  stats: const ItemStats(),
);

ProfilePage _page(String id, {String cursor = '', bool? following}) =>
    ProfilePage(
      ref: _profile,
      name: '作者',
      items: <FeedItem>[_note(id)],
      nextCursor: cursor,
      hasMore: cursor.isNotEmpty,
      following: following,
    );

class _XhsSource implements XhsWebSource {
  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{
    SourceCapability.follow,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TiebaSource implements TiebaSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends MixsocialController {
  _Controller()
    : super(
        xhs: _XhsSource(),
        tieba: _TiebaSource(),
        settings: LocalSettings(SharedPreferencesAsync()),
      );
  Future<ProfilePage> Function(ProfileSection section, String cursor)?
  onProfile;
  Future<String?> Function(bool value)? onFollow;
  int followCalls = 0;

  @override
  Future<ProfilePage> profile(
    ProfileRef profile, {
    ProfileSection section = ProfileSection.notes,
    String cursor = '',
  }) async => onProfile == null ? _page('笔记') : onProfile!(section, cursor);

  @override
  Future<String?> follow(ProfileRef profile, bool value) async {
    followCalls++;
    return await onFollow?.call(value);
  }
}

Future<void> _show(
  WidgetTester tester,
  _Controller controller, {
  bool own = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ProfileScreen(
        controller: controller,
        author: _author,
        isOwnProfile: own,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late _Controller controller;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    controller = _Controller();
  });
  tearDown(() => controller.dispose());

  testWidgets(
    'switching profile sections discards an old pagination response',
    (tester) async {
      final oldPage = Completer<ProfilePage>();
      controller.onProfile = (section, cursor) async {
        if (section == ProfileSection.favorites) return _page('收藏结果');
        if (cursor.isNotEmpty) return oldPage.future;
        return _page('笔记结果', cursor: 'next');
      };
      await _show(tester, controller);
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      oldPage.complete(_page('过期分页'));
      await tester.pumpAndSettle();
      expect(find.text('收藏结果'), findsOneWidget);
      expect(find.text('过期分页'), findsNothing);
      expect(find.text('笔记结果'), findsNothing);
    },
  );

  testWidgets('refresh ignores an old pagination error', (tester) async {
    final oldPage = Completer<ProfilePage>();
    var firstLoads = 0;
    controller.onProfile = (_, cursor) async {
      if (cursor.isNotEmpty) return oldPage.future;
      firstLoads++;
      return _page(firstLoads == 1 ? '旧笔记' : '刷新结果', cursor: 'next');
    };
    await _show(tester, controller);
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    oldPage.completeError(StateError('stale failure'));
    await tester.pumpAndSettle();
    expect(find.text('刷新结果'), findsOneWidget);
    expect(find.text('加载更多失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pagination failure pauses automatic requests and can be retried',
    (tester) async {
      var requests = 0;
      controller.onProfile = (_, cursor) async {
        if (cursor.isEmpty) return _page('第一页', cursor: 'next');
        requests++;
        if (requests == 1) throw StateError('offline');
        return _page('第二页');
      };
      await _show(tester, controller);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.text('加载更多失败'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.ensureVisible(find.text('重试加载更多'));
      await tester.tap(find.text('重试加载更多'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(find.text('第二页'), findsOneWidget);
      expect(find.text('加载更多失败'), findsNothing);
    },
  );

  testWidgets('own profile hides relationship actions', (tester) async {
    await _show(tester, controller, own: true);
    expect(find.widgetWithText(FilledButton, '关注'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '已关注'), findsNothing);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('点赞'), findsOneWidget);
  });

  testWidgets(
    'profile uses observed relationship and surfaces local-write warning',
    (tester) async {
      controller.onProfile = (_, _) async => _page('笔记', following: true);
      controller.onFollow = (value) async {
        expect(value, isFalse);
        return '小红书已取消关注，但本地记录保存失败';
      };
      await _show(tester, controller);
      await tester.tap(find.widgetWithText(OutlinedButton, '已关注'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '关注'), findsOneWidget);
      expect(find.textContaining('本地记录保存失败'), findsOneWidget);
    },
  );

  testWidgets(
    'follow rejection retains state and pending action cannot double submit',
    (tester) async {
      final response = Completer<String?>();
      controller.onFollow = (_) => response.future;
      await _show(tester, controller);
      await tester.tap(find.widgetWithText(FilledButton, '关注'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '关注'))
            .onPressed,
        isNull,
      );
      response.completeError(StateError('rejected'));
      await tester.pumpAndSettle();
      expect(controller.followCalls, 1);
      expect(find.widgetWithText(FilledButton, '关注'), findsOneWidget);
      expect(find.textContaining('平台数据暂时不可用'), findsOneWidget);
    },
  );
}
