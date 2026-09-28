import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/comment_composer.dart';
import 'package:mixsocial_mobile/src/comment_drafts.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Future<void> _open(
  WidgetTester tester, {
  required CommentDraftStore drafts,
  required Future<void> Function(String) onSend,
  bool handoff = false,
  String key = 'note:root',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCommentComposer(
              context,
              title: '回复测试作者',
              hint: '输入回复',
              draftKey: key,
              drafts: drafts,
              replyPreview: '23楼 · 测试作者：原始回复内容',
              onSend: onSend,
              externalHandoff: handoff,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );

  testWidgets(
    'closing saves exact text and reopening restores the correct target',
    (tester) async {
      final drafts = CommentDraftStore();
      await _open(tester, drafts: drafts, onSend: (_) async {});
      expect(find.text('23楼 · 测试作者：原始回复内容'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('comment-input')),
        '  有换行\n的草稿  ',
      );
      await tester.tap(find.byTooltip('保存草稿并关闭'));
      await tester.pumpAndSettle();
      expect((await drafts.read('note:root'))?.body, '  有换行\n的草稿  ');
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('comment-input')))
            .controller
            ?.text,
        '  有换行\n的草稿  ',
      );
      expect(await drafts.read('note:other-reply'), isNull);
    },
  );

  testWidgets('confirmed send clears only this draft and dispatches once', (
    tester,
  ) async {
    final drafts = CommentDraftStore();
    var requests = 0;
    final pending = Completer<void>();
    await _open(
      tester,
      drafts: drafts,
      onSend: (body) {
        requests++;
        expect(body, '正文');
        return pending.future;
      },
    );
    await tester.enterText(find.byKey(const Key('comment-input')), ' 正文 ');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pump();
    expect(requests, 1);
    expect((await drafts.read('note:root'))?.unconfirmed, isTrue);
    final send = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(send.onPressed, isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(await drafts.read('note:root'), isNull);
    expect(find.byKey(const Key('comment-input')), findsNothing);
  });

  testWidgets(
    'unknown send keeps text and blocks blind retries across reopening',
    (tester) async {
      final drafts = CommentDraftStore();
      var requests = 0;
      await _open(
        tester,
        drafts: drafts,
        onSend: (_) async {
          requests++;
          throw StateError('发送结果未知');
        },
      );
      await tester.enterText(find.byKey(const Key('comment-input')), '保留的正文');
      await tester.pump();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('comment-input')))
            .controller
            ?.text,
        '保留的正文',
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect((await drafts.read('note:root'))?.unconfirmed, isTrue);
      await tester.tap(find.byTooltip('保存草稿并关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('我已核对，确认未发送'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(requests, 1);
    },
  );

  testWidgets('explicit clear removes draft without sending', (tester) async {
    final drafts = CommentDraftStore();
    await drafts.save(
      'note:root',
      const CommentDraft(body: '旧草稿', unconfirmed: true),
    );
    await _open(
      tester,
      drafts: drafts,
      onSend: (_) async => fail('must not send'),
    );
    await tester.tap(find.text('清空草稿'));
    await tester.pumpAndSettle();
    expect(await drafts.read('note:root'), isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('comment-input')))
          .controller
          ?.text,
      '',
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets(
    'official-web handoff does not claim delivery or clear local draft',
    (tester) async {
      final drafts = CommentDraftStore();
      var copied = '';
      await _open(
        tester,
        drafts: drafts,
        handoff: true,
        onSend: (body) async => copied = body,
      );
      expect(find.textContaining('此处仅准备草稿'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('comment-input')), '贴吧草稿');
      await tester.pump();
      await tester.tap(find.text('复制并前往官方页'));
      await tester.pumpAndSettle();
      expect(copied, '贴吧草稿');
      expect((await drafts.read('note:root'))?.body, '贴吧草稿');
      expect((await drafts.read('note:root'))?.unconfirmed, isFalse);
      expect(find.text('回复已发送'), findsNothing);
    },
  );

  testWidgets('composer stays scrollable with keyboard and long errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 500);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await _open(
      tester,
      drafts: CommentDraftStore(),
      onSend: (_) async => throw StateError('拒绝发送'),
    );
    await tester.enterText(find.byKey(const Key('comment-input')), '正文');
    await tester.ensureVisible(find.text('发送'));
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
