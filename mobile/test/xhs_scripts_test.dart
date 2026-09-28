import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/xhs_scripts.dart';

void main() {
  test('floor reply parser preserves nested comment pictures', () {
    final script = xhsFloorRepliesScript('note-1', 'comment-1');

    expect(script, contains('comment.pictures'));
    expect(script, contains("'imageList', 'image_list'"));
    expect(script, contains("kind: 'image'"));
    expect(script, contains('previewUrl:'));
  });

  test('floor reply expansion supports current and fallback controls', () {
    final script = xhsLoadMoreFloorRepliesScript('comment-1');

    expect(script, contains('[data-comment-id]'));
    expect(script, contains('.show-more, .show-more-container, .more-replies'));
    expect(script, contains('pointerdown'));
    expect(script, contains('button.click()'));
  });

  test('detail parser preserves separate high and preview image scenes', () {
    final script = xhsDetailScript('note-1', 'token-1');

    expect(script, contains('entry.imageScene'));
    expect(script, contains('/ori|origin/i'));
    expect(script, contains('/dft|default/i'));
    expect(script, contains('/prv|preview/i'));
    expect(script, contains('url: highImage(image)'));
    expect(script, contains('previewUrl: previewImage(image)'));
    expect(script, contains('url: highImage(picture)'));
  });

  test('feed and profile cards retain high-quality cover fallbacks', () {
    expect(xhsFeedScript, contains('const coverUrl = highImage(cover)'));
    final profile = xhsProfileScript('user-1', 'token-1');
    expect(profile, contains('const coverUrl = highImage(cover)'));
    expect(profile, contains('previewUrl: coverPreviewUrl || coverUrl'));
  });

  test('floor parser unwraps Vue refs and snake-case replies', () async {
    final result = await _parse(
      xhsFloorRepliesScript('note-1', 'root-1'),
      state: _noteState(<String, Object?>{
        'id': 'root-1',
        'sub_comment_count': 12,
        'sub_comment_has_more': false,
        'sub_comment_cursor': 'finished',
        'sub_comments': <String, Object?>{
          '_rawValue': <Object?>[
            <String, Object?>{
              'id': 'reply-1',
              'content': '实际回复',
              'like_count': '1.2万',
              'is_liked': <String, Object?>{'value': true},
              'create_time': 1700000000,
              'user_info': <String, Object?>{
                'user_id': 'author-1',
                'nickname': '回复者',
                'image': <String, Object?>{'url': '//sns-avatar.xhscdn.com/a'},
              },
              'pictures': <Object?>[
                <String, Object?>{
                  'urlDefault': 'https://example.invalid/photo',
                },
              ],
            },
          ],
        },
      }),
    );

    final replies = result['comments'] as List<dynamic>;
    expect(replies, hasLength(1));
    expect(replies.single['body'], '实际回复');
    expect(replies.single['likes'], 12000);
    expect(replies.single['liked'], isTrue);
    expect(replies.single['ref']['parentId'], 'root-1');
    expect(replies.single['author']['id'], 'author-1');
    expect(replies.single['author']['avatar'], '//sns-avatar.xhscdn.com/a');
    expect(replies.single['media'], hasLength(1));
    // The count can include deleted replies; an explicit end must win.
    expect(result['hasMore'], isFalse);
    expect(jsonDecode(result['nextCursor'] as String)['cursor'], 'finished');
  });

  test('floor parser reads live Vue props after expansion', () async {
    final result = await _parse(
      xhsFloorRepliesScript('note-1', 'root-1'),
      state: _noteState(<String, Object?>{
        'id': 'root-1',
        'subComments': <Object?>[],
        'subCommentCount': 2,
      }),
      setup:
          _commentDom +
          r'''
        item.__vueParentComponent = {props: {comment: {value: {
          id: 'root-1', subCommentCount: 2, subCommentHasMore: false,
          subComments: [{id: 'reply-live', content: '新加载回复'}]
        }}}};
      ''',
    );

    expect((result['comments'] as List).single['body'], '新加载回复');
    expect(result['hasMore'], isFalse);
  });

  test(
    'expansion finds raw-id sibling control in an offscreen WebView',
    () async {
      final result = await _execute(
        xhsLoadMoreFloorRepliesScript('root-1'),
        setup: _commentDom,
      );

      expect(result['value'], isTrue);
      expect(result['clicks'], 1);
    },
  );

  test('expansion does not click disabled or hidden controls', () async {
    for (final setup in <String>[
      'button.disabled = true;',
      'root.hidden = true;',
      "button.textContent = '收起回复';",
    ]) {
      final result = await _execute(
        xhsLoadMoreFloorRepliesScript('root-1'),
        setup: _commentDom + setup,
      );
      expect(result['value'], isFalse);
      expect(result['clicks'], 0);
    }
  });

  test(
    'detail keeps nested replies and respects explicit root pagination end',
    () async {
      final result = await _parse(
        xhsDetailScript('note-1', 'token-1'),
        state: _noteState(<String, Object?>{
          'id': 'root-1',
          'content': '顶层评论',
          'liked': false,
          'sub_comment_count': 1,
          'sub_comments': <Object?>[
            <String, Object?>{'id': 'reply-1', 'content': '楼中楼'},
          ],
        }),
      );

      final comment = (result['comments'] as List).single;
      expect(comment['ref']['parentId'], 'note-1');
      expect(comment['replyCount'], 1);
      expect(comment['liked'], isFalse);
      expect((comment['replies'] as List).single['liked'], isNull);
      expect((comment['replies'] as List).single['ref']['parentId'], 'root-1');
      expect(result['hasMore'], isFalse);
    },
  );

  test('feed retains avatar candidates without stringifying objects', () async {
    final result = await _parse(
      xhsFeedScript,
      state: <String, Object?>{
        'feed': <String, Object?>{
          'feeds': <Object?>[
            <String, Object?>{
              'id': 'note-1',
              'noteCard': <String, Object?>{
                'user': <String, Object?>{
                  'avatar': <String, Object?>{
                    'url': '//sns-avatar.xhscdn.com/a',
                  },
                  'image': 'https://sns-avatar.xhscdn.com/b?sign=keep',
                  'images': <String>['https://sns-avatar.xhscdn.com/c'],
                },
              },
            },
          ],
        },
      },
    );
    final author = (result['items'] as List).single['author'];
    expect(author['avatar'], '//sns-avatar.xhscdn.com/a');
    expect(author['avatar_urls'], <String>[
      '//sns-avatar.xhscdn.com/a',
      'https://sns-avatar.xhscdn.com/b?sign=keep',
      'https://sns-avatar.xhscdn.com/c',
    ]);
  });

  test(
    'detail merges root comments loaded only into live components',
    () async {
      final result = await _parse(
        xhsDetailScript('note-1', 'token-1'),
        state: _noteState(<String, Object?>{
          'id': 'initial-1',
          'content': '首屏',
        }),
        setup:
            _commentDom +
            r'''
        item.__vueParentComponent = {props: {comment: {
          id: 'root-1', content: '滚动后评论', subComments: []
        }}};
        document.querySelectorAll = (selector) => selector === '.parent-comment' ? [root] : [];
      ''',
      );

      expect(
        (result['comments'] as List).map((dynamic comment) => comment['body']),
        <String>['首屏', '滚动后评论'],
      );
    },
  );
}

Map<String, Object?> _noteState(Map<String, Object?> comment) =>
    <String, Object?>{
      'note': <String, Object?>{
        'noteDetailMap': <String, Object?>{
          '_value': <String, Object?>{
            'note-1': <String, Object?>{
              'note': <String, Object?>{
                'value': <String, Object?>{
                  'noteId': 'note-1',
                  'xsecToken': 'token-1',
                  'interactInfo': <String, Object?>{'commentCount': 99},
                },
              },
              'comments': <String, Object?>{
                '_rawValue': <String, Object?>{
                  'list': <String, Object?>{
                    'value': <Object?>[comment],
                  },
                  'has_more': false,
                },
              },
            },
          },
        },
      },
    };

// The web page commonly places the raw comment id on a child, and the expand
// control beside that child. Offscreen WebViews can report zero layout sizes.
const _commentDom = r'''
  const button = {
    textContent: '展开 2 条回复',
    matches: () => true,
    getBoundingClientRect: () => ({width: 0, height: 0}),
    dispatchEvent: () => {},
    click: () => { clicks++; },
  };
  const root = {
    querySelectorAll: () => [button],
    querySelector: () => item,
    scrollIntoView: () => {},
  };
  const item = {id: 'root-1', closest: () => root};
  button.parentElement = root;
  document.getElementById = (id) => id === 'root-1' ? item : null;
''';

Future<Map<String, dynamic>> _parse(
  String script, {
  Map<String, Object?> state = const <String, Object?>{},
  String setup = '',
}) async {
  final result = await _execute(script, state: state, setup: setup);
  return jsonDecode(result['value'] as String) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _execute(
  String script, {
  Map<String, Object?> state = const <String, Object?>{},
  String setup = '',
}) async {
  // Execute the generated JavaScript, not just a substring check. These tests
  // need Node.js on the host but never access the network or an account.
  final result = await Process.run('node', <String>[
    '-e',
    '''
      const window = {__INITIAL_STATE__: ${jsonEncode(state)}};
      const document = {
        getElementById: () => null,
        querySelector: () => null,
        querySelectorAll: () => [],
      };
      const getComputedStyle = () => ({display: 'block', visibility: 'visible'});
      const MouseEvent = function() {};
      let clicks = 0;
      $setup
      const value = eval(${jsonEncode(script)});
      process.stdout.write(JSON.stringify({value, clicks}));
    ''',
  ]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}
