import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/detail_screen.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_comment_interaction_scripts.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _note = FeedItem(
  ref: ContentRef(source: SourceId.xhs, id: 'note'),
  title: '评论互动测试',
  author: Author(
    ref: ProfileRef(source: SourceId.xhs, id: 'author'),
    id: 'author',
    name: '作者',
  ),
  stats: ItemStats(),
);
const _reply = FeedComment(
  ref: ContentRef(source: SourceId.xhs, id: 'reply', parentId: 'root'),
  author: Author(
    ref: ProfileRef(source: SourceId.xhs, id: 'reader'),
    id: 'reader',
    name: '回复者',
  ),
  body: '楼中楼内容',
  likes: 2,
  liked: false,
);
const _root = FeedComment(
  ref: ContentRef(source: SourceId.xhs, id: 'root', parentId: 'note'),
  author: Author(
    ref: ProfileRef(source: SourceId.xhs, id: 'reader'),
    id: 'reader',
    name: '读者',
  ),
  body: '根评论内容',
  likes: 4,
  liked: false,
  replyCount: 1,
  replies: <FeedComment>[_reply],
);

class _Xhs implements XhsWebSource {
  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{
    SourceCapability.commentLike,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tieba implements TiebaSource {
  @override
  Set<SourceCapability> get capabilities => <SourceCapability>{};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends MixsocialController {
  _Controller()
    : super(
        xhs: _Xhs(),
        tieba: _Tieba(),
        settings: LocalSettings(SharedPreferencesAsync()),
      );

  FeedComment loadedComment = _root;
  Future<void> Function()? onLike;
  final List<(String, bool)> writes = <(String, bool)>[];

  @override
  Future<bool> isReadLater(FeedItem item) async => false;

  @override
  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) async =>
      FeedDetail(item: _note, body: '', comments: <FeedComment>[loadedComment]);

  @override
  bool supportsFloorReplies(SourceId source) => true;

  @override
  Future<FeedCommentPage> floorReplies(
    ContentRef floor, {
    String cursor = '',
  }) async => const FeedCommentPage(comments: <FeedComment>[_reply]);

  @override
  Future<void> commentLike(
    ContentRef ref,
    ContentRef comment,
    bool value,
  ) async {
    expect(ref.id, 'note');
    writes.add((comment.id, value));
    await onLike?.call();
  }
}

Future<void> _show(WidgetTester tester, _Controller controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DetailScreen(controller: controller, initialItem: _note),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _button(String id) => find.byKey(ValueKey<String>('comment-like-$id'));

Future<Object?> _runScript(String script, {String setup = ''}) async {
  final result = await Process.run('node', <String>[
    '-e',
    '''
$_dom
$setup
console.log(JSON.stringify($script));
''',
  ]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
  return jsonDecode(result.stdout.toString());
}

const _dom = r'''
global.window = {__INITIAL_STATE__: {note: {noteDetailMap: {note: {
  comments: {list: [{id: 'root', liked: false, subComments: [{id: 'reply', liked: true}]}]}
}}}}};
global.getComputedStyle = (node) => ({display: node.hidden ? 'none' : 'block', visibility: 'visible'});
const root = {id: 'comment-root', dataset: {}};
const reply = {id: 'comment-reply', dataset: {}};
let rootClicks = 0, replyClicks = 0;
const rootButton = {closest: () => root, click: () => rootClicks++, getAttribute: () => null};
const replyButton = {closest: () => reply, click: () => replyClicks++, getAttribute: () => null};
// Deliberately place the nested button first; a broad descendant selector must
// never choose it when the user intended the parent's like control.
root.querySelectorAll = () => [replyButton, rootButton];
reply.querySelectorAll = () => [replyButton];
root.querySelector = reply.querySelector = () => null;
global.document = {
  getElementById: (id) => id === root.id ? root : id === reply.id ? reply : null,
  querySelectorAll: (selector) => selector === '.parent-comment' ? [] : [root, reply],
};
''';

void main() {
  test('comment model preserves known and unknown like state in copies', () {
    for (final value in <Object?>[true, false, null, 'false', 0]) {
      final comment = FeedComment.fromJson(<String, Object?>{
        'id': 'comment',
        'liked': value,
        'likes': 5,
      }, SourceId.xhs);
      expect(comment.liked, value is bool ? value : null);
      expect(comment.copyWith(replies: <FeedComment>[]).liked, comment.liked);
      expect(comment.copyWith(likes: 6, liked: true).likes, 6);
    }
  });

  test('comment state keeps parent and nested reply separate', () async {
    expect(
      await _runScript(xhsCommentLikeStateScript('note', 'root')),
      'false',
    );
    expect(
      await _runScript(xhsCommentLikeStateScript('note', 'reply')),
      'true',
    );
  });

  test('a root click cannot select a nested reply control', () async {
    final script = xhsClickCommentLikeScript('root');
    expect(
      await _runScript(
        '(() => {const clicked = $script; return [clicked, rootClicks, replyClicks];})()',
      ),
      <Object?>[true, 1, 0],
    );
  });

  test('a nested click cannot select its parent control', () async {
    final script = xhsClickCommentLikeScript('reply');
    expect(
      await _runScript(
        '(() => {const clicked = $script; return [clicked, rootClicks, replyClicks];})()',
      ),
      <Object?>[true, 0, 1],
    );
  });

  test(
    'Vue fallback cannot inherit a different comment target from its parent',
    () async {
      expect(
        await _runScript(
          xhsClickCommentLikeScript('root'),
          setup: """
          root.id = ''; reply.id = '';
          root.__vueParentComponent = {props: {comment: {id: 'root'}}};
          reply.__vueParentComponent = {props: {comment: {id: 'reply'}}, parent: root.__vueParentComponent};
          root.querySelectorAll = () => [replyButton];
        """,
        ),
        isFalse,
      );
    },
  );

  test(
    'missing state stays unknown and missing target is not clicked',
    () async {
      expect(
        await _runScript(
          xhsCommentLikeStateScript('note', 'root'),
          setup: 'window.__INITIAL_STATE__ = {};',
        ),
        '',
      );
      expect(await _runScript(xhsClickCommentLikeScript('missing')), isFalse);
    },
  );

  test('live Vue bool state takes precedence over the SSR snapshot', () async {
    expect(
      await _runScript(
        xhsCommentLikeStateScript('note', 'root'),
        setup:
            "root.__vueParentComponent = {props: {comment: {value: {id: 'root', liked: true}}}};",
      ),
      'true',
    );
  });

  test(
    'disabled control remains unusable and aria-pressed can supply state',
    () async {
      expect(
        await _runScript(
          xhsCommentLikeStateScript('note', 'root'),
          setup: 'rootButton.disabled = true;',
        ),
        '',
      );
      expect(
        await _runScript(
          xhsCommentLikeStateScript('note', 'reply'),
          setup:
              "window.__INITIAL_STATE__ = {}; replyButton.getAttribute = (key) => key === 'aria-pressed' ? 'false' : null;",
        ),
        'false',
      );
    },
  );

  group('comment like UI', () {
    late _Controller controller;

    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      controller = _Controller();
    });
    tearDown(() => controller.dispose());

    testWidgets('waits for confirmation and disables duplicate taps', (
      tester,
    ) async {
      final pending = Completer<void>();
      controller.onLike = () => pending.future;
      await _show(tester, controller);
      await tester.ensureVisible(_button('root'));
      await tester.tap(_button('root'));
      await tester.pump();
      expect(tester.widget<TextButton>(_button('root')).onPressed, isNull);
      expect(
        find.descendant(of: _button('root'), matching: find.text('4')),
        findsOneWidget,
      );
      expect(controller.writes, <(String, bool)>[('root', true)]);
      pending.complete();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _button('root'), matching: find.text('5')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _button('root'),
          matching: find.byIcon(Icons.thumb_up_alt),
        ),
        findsOneWidget,
      );
      await tester.tap(_button('root'));
      await tester.pumpAndSettle();
      expect(controller.writes.last, ('root', false));
      expect(
        find.descendant(of: _button('root'), matching: find.text('4')),
        findsOneWidget,
      );
    });

    testWidgets('rejection preserves count and allows an explicit retry', (
      tester,
    ) async {
      controller.onLike = () async => throw StateError('请先登录');
      await _show(tester, controller);
      await tester.ensureVisible(_button('root'));
      await tester.tap(_button('root'));
      await tester.pumpAndSettle();
      expect(find.textContaining('登录状态无法确认'), findsOneWidget);
      expect(
        find.descendant(of: _button('root'), matching: find.text('4')),
        findsOneWidget,
      );
      expect(tester.widget<TextButton>(_button('root')).onPressed, isNotNull);
      expect(
        find.descendant(
          of: _button('root'),
          matching: find.byIcon(Icons.thumb_up_alt),
        ),
        findsNothing,
      );
    });

    testWidgets('unknown state does not invent a count increment', (
      tester,
    ) async {
      controller.loadedComment = FeedComment(
        ref: _root.ref,
        author: _root.author,
        body: _root.body,
        likes: 4,
      );
      await _show(tester, controller);
      await tester.ensureVisible(_button('root'));
      await tester.tap(_button('root'));
      await tester.pumpAndSettle();
      expect(controller.writes.single, ('root', true));
      expect(
        find.descendant(of: _button('root'), matching: find.text('4')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _button('root'),
          matching: find.byIcon(Icons.thumb_up_alt),
        ),
        findsOneWidget,
      );
    });

    testWidgets('floor root likes synchronize back to the parent detail', (
      tester,
    ) async {
      await _show(tester, controller);
      await tester.ensureVisible(find.text('查看楼中楼'));
      await tester.tap(find.text('查看楼中楼'));
      await tester.pumpAndSettle();
      await tester.tap(_button('root'));
      await tester.pumpAndSettle();
      await tester.tap(_button('reply'));
      await tester.pumpAndSettle();
      expect(controller.writes, <(String, bool)>[
        ('root', true),
        ('reply', true),
      ]);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(_button('root'));
      expect(
        find.descendant(of: _button('root'), matching: find.text('5')),
        findsOneWidget,
      );
      // Reopening uses the updated nested preview, even before another read.
      await tester.ensureVisible(find.text('查看楼中楼'));
      await tester.tap(find.text('查看楼中楼'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _button('root'), matching: find.text('5')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _button('reply'), matching: find.text('3')),
        findsOneWidget,
      );
    });

    testWidgets(
      'failed floor write after going back releases parent and reports error',
      (tester) async {
        final pending = Completer<void>();
        controller.onLike = () => pending.future;
        await _show(tester, controller);
        await tester.ensureVisible(find.text('查看楼中楼'));
        await tester.tap(find.text('查看楼中楼'));
        await tester.pumpAndSettle();
        await tester.tap(_button('root'));
        await tester.pump();
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        await tester.ensureVisible(_button('root'));
        expect(tester.widget<TextButton>(_button('root')).onPressed, isNull);
        pending.completeError(StateError('服务器拒绝点赞'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextButton>(_button('root')).onPressed, isNotNull);
        expect(find.textContaining('平台数据暂时不可用'), findsOneWidget);
        expect(
          find.descendant(of: _button('root'), matching: find.text('4')),
          findsOneWidget,
        );
        controller.onLike = null;
        await tester.tap(_button('root'));
        await tester.pumpAndSettle();
        expect(controller.writes, <(String, bool)>[
          ('root', true),
          ('root', true),
        ]);
        expect(
          find.descendant(of: _button('root'), matching: find.text('5')),
          findsOneWidget,
        );
      },
    );
  });
}
