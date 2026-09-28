// Keep browser fixture fragments raw: Dart interpolation would escape or expand
// JavaScript syntax and make the scripts under test harder to inspect.
// ignore_for_file: prefer_interpolation_to_compose_strings, prefer_adjacent_string_concatenation

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/xhs_interaction_scripts.dart';
import 'package:mixsocial_mobile/src/xhs_scripts.dart';

// Node executes the exact injected JavaScript with mocked browser transports.
// These tests never contact Xiaohongshu or perform real account writes.
Future<void> _runJavaScript(String body) async {
  final result = await Process.run('node', <String>[
    '-e',
    '''
const assert = require('node:assert/strict');
global.window = global;
global.location = {href: 'https://www.xiaohongshu.com/explore/note-1'};
const tick = () => new Promise((resolve) => setImmediate(resolve));
(async () => {
''' +
        body +
        '''
})().catch((error) => { console.error(error); process.exitCode = 1; });
''',
  ]);
  expect(
    result.exitCode,
    0,
    reason: result.stdout.toString() + result.stderr.toString(),
  );
}

String _observe({
  String action = 'comment',
  bool value = false,
  String targetId = '',
  String content = '同一条评论',
  String profileId = '',
}) =>
    xhsInstallInteractionObserverScript +
    ';\nassert.equal(' +
    xhsBeginInteractionScript(
      operationId: 'operation-1',
      noteId: 'note-1',
      action: action,
      value: value,
      content: content,
      targetId: targetId,
      profileId: profileId,
    ) +
    r''', true);
const result = () => JSON.parse(window.__mixsocialXhsInteraction.result('operation-1'));
''';

void main() {
  test(
    'invalid observer operations cannot leave an unguarded submission',
    () async {
      await _runJavaScript(
        xhsInstallInteractionObserverScript +
            r''';
const spec = {id: 'operation-1', action: 'follow', profileId: 'profile-1', value: true};
const begin = window.__mixsocialXhsInteraction.begin;
assert.equal(begin({...spec, profileId: ''}), false);
assert.equal(begin({...spec, action: 'unsupported'}), false);
assert.equal(begin({...spec, value: 'true'}), false);
assert.equal(begin({...spec, action: 'like'}), false);
assert.equal(begin({...spec, action: 'commentLike', noteId: 'note-1'}), false);
assert.equal(begin({...spec, action: 'comment', noteId: 'note-1', content: '   ', targetId: ''}), false);
assert.equal(window.__mixsocialXhsInteraction.pending, null);
assert.equal(begin(spec), true);
''',
      );
    },
  );

  test('like and favorite cannot act on a different note', () async {
    for (final action in <String>['like', 'favorite']) {
      await _runJavaScript(
        r'''
let sent = 0;
window.fetch = async () => { sent++; return new Response('{}'); };
''' +
            _observe(action: action, value: true) +
            'await assert.rejects(window.fetch(' +
            jsonEncode(
              '/api/sns/web/v1/note/' + (action == 'like' ? 'like' : 'collect'),
            ) +
            r''', {method: 'POST', body: '{"note_id":"wrong-note"}'}));
assert.equal(sent, 0);
assert.equal(result().status, 'error');
''',
      );
    }
  });

  test(
    'fetch waits for server success and preserves the original response',
    () async {
      await _runJavaScript(
        r'''
let resolveResponse;
window.fetch = () => new Promise((resolve) => { resolveResponse = resolve; });
''' +
            _observe() +
            r'''
const request = window.fetch('https://edith.xiaohongshu.com/api/sns/web/v1/comment/post', {
  method: 'POST', body: JSON.stringify({note_id: 'note-1', content: '同一条评论'})
});
window.__INITIAL_STATE__ = {comments: ['同一条评论']};
assert.equal(result().status, 'pending');
const response = new Response(JSON.stringify({success: true, code: 0, data: {id: 'new-id'}}));
resolveResponse(response);
assert.equal(await request, response);
await tick();
assert.equal(result().status, 'success');
assert.equal((await response.json()).data.id, 'new-id');
''',
      );
    },
  );

  test('optimistic likes do not hide server refusal', () async {
    await _runJavaScript(
      r'''
window.fetch = async () => new Response(JSON.stringify({success: false, code: 300012, msg: '请先登录'}));
''' +
          _observe(action: 'like', value: true) +
          r'''
window.__INITIAL_STATE__ = {liked: true};
await window.fetch('/api/sns/web/v1/note/like', {method: 'POST', body: '{"note_oid":"note-1"}'});
await tick();
assert.equal(result().status, 'error');
assert.equal(result().message, '请先登录');
''',
    );
  });

  test(
    'like and collection endpoints match their actual note ID fields',
    () async {
      for (final operation in <(String, bool, String, String)>[
        ('like', true, 'like', 'note_oid'),
        ('like', false, 'dislike', 'note_oid'),
        ('favorite', true, 'collect', 'note_id'),
        ('favorite', false, 'uncollect', 'note_ids'),
      ]) {
        await _runJavaScript(
          r'''
window.fetch = async () => new Response(JSON.stringify({success: true}));
''' +
              _observe(action: operation.$1, value: operation.$2) +
              'await window.fetch(' +
              jsonEncode('/api/sns/web/v1/note/' + operation.$3) +
              ', {method: "POST", body: ' +
              jsonEncode(jsonEncode(<String, String>{operation.$4: 'note-1'})) +
              r'''});
await tick();
assert.equal(result().status, 'success');
''',
        );
      }
    },
  );

  test(
    'unrelated actions, origins and methods cannot confirm a like',
    () async {
      await _runJavaScript(
        r'''
window.fetch = async () => new Response(JSON.stringify({success: true}));
''' +
            _observe(action: 'like', value: true) +
            r'''
await window.fetch('/api/sns/web/v1/comment/like', {method: 'POST', body: '{"note_id":"note-1","comment_id":"comment-1"}'});
await window.fetch('https://xiaohongshu.com.example.org/api/sns/web/v1/note/like', {
  method: 'POST', body: '{"note_oid":"note-1"}'
});
await window.fetch('/api/sns/web/v1/note/like', {method: 'GET', body: '{"note_oid":"note-1"}'});
await tick();
assert.equal(result().status, 'pending');
assert.equal(result().sent, false);
''',
      );
    },
  );

  test(
    'follow and comment likes require matching server confirmation',
    () async {
      for (final action in <String>['follow', 'commentLike']) {
        for (final value in <bool>[true, false]) {
          final suffix = action == 'follow'
              ? 'user/${value ? 'follow' : 'unfollow'}'
              : 'comment/${value ? 'like' : 'dislike'}';
          final body = action == 'follow'
              ? <String, String>{'target_user_id': 'profile-1'}
              : <String, String>{
                  'note_id': 'note-1',
                  'comment_id': 'comment-1',
                };
          await _runJavaScript(
            r'''
let resolveResponse;
let sent = 0;
window.fetch = () => {
  sent++;
  return new Promise((resolve) => { resolveResponse = resolve; });
};
''' +
                _observe(
                  action: action,
                  value: value,
                  profileId: 'profile-1',
                  targetId: 'comment-1',
                ) +
                'const args = [' +
                jsonEncode(
                  'https://edith.xiaohongshu.com/api/sns/web/v1/$suffix',
                ) +
                ', {method: "POST", body: ' +
                jsonEncode(jsonEncode(body)) +
                r'''}];
const request = window.fetch(...args);
assert.equal(result().status, 'pending');
assert.equal(result().sent, true);
resolveResponse(new Response(JSON.stringify({success: true, code: 0})));
await request;
await tick();
assert.equal(result().status, 'success');
await assert.rejects(window.fetch(...args));
assert.equal(sent, 1);
''',
          );
        }
      }
    },
  );

  test(
    'follow and comment likes reject wrong targets before sending',
    () async {
      for (final fixture in <(String, String, Map<String, Object>)>[
        (
          'follow',
          'user/follow',
          <String, Object>{'target_user_id': 'wrong-profile'},
        ),
        ('follow', 'user/follow', <String, Object>{'user_id': 'profile-1'}),
        (
          'commentLike',
          'comment/like',
          <String, Object>{'note_id': 'wrong-note', 'comment_id': 'comment-1'},
        ),
        (
          'commentLike',
          'comment/like',
          <String, Object>{'note_id': 'note-1', 'comment_id': 'wrong-comment'},
        ),
        ('commentLike', 'comment/like', <String, Object>{'note_id': 'note-1'}),
        (
          'favorite',
          'note/collect',
          <String, Object>{
            'note_ids': <String>['note-1', 'another-note'],
          },
        ),
      ]) {
        await _runJavaScript(
          r'''
let sent = 0;
window.fetch = async () => { sent++; return new Response('{}'); };
''' +
              _observe(
                action: fixture.$1,
                value: true,
                profileId: 'profile-1',
                targetId: 'comment-1',
              ) +
              'await assert.rejects(window.fetch(' +
              jsonEncode('/api/sns/web/v1/${fixture.$2}') +
              ', {method: "POST", body: ' +
              jsonEncode(jsonEncode(fixture.$3)) +
              r'''}));
assert.equal(sent, 0);
assert.equal(result().status, 'error');
assert.equal(result().sent, false);
''',
        );
      }
    },
  );

  test(
    'opposite-direction website requests cannot change account state',
    () async {
      for (final fixture in <(String, String, String, Map<String, String>)>[
        (
          'like',
          'note/like',
          'note/dislike',
          <String, String>{'note_oid': 'note-1'},
        ),
        (
          'favorite',
          'note/collect',
          'note/uncollect',
          <String, String>{'note_ids': 'note-1'},
        ),
        (
          'follow',
          'user/follow',
          'user/unfollow',
          <String, String>{'target_user_id': 'profile-1'},
        ),
        (
          'commentLike',
          'comment/like',
          'comment/dislike',
          <String, String>{'note_id': 'note-1', 'comment_id': 'comment-1'},
        ),
      ]) {
        for (final value in <bool>[true, false]) {
          await _runJavaScript(
            r'''
let sent = 0;
window.fetch = async () => { sent++; return new Response('{}'); };
''' +
                _observe(
                  action: fixture.$1,
                  value: value,
                  profileId: 'profile-1',
                  targetId: 'comment-1',
                ) +
                'await assert.rejects(window.fetch(' +
                jsonEncode(
                  '/api/sns/web/v1/${value ? fixture.$3 : fixture.$2}',
                ) +
                ', {method: "POST", body: ' +
                jsonEncode(jsonEncode(fixture.$4)) +
                r'''}));
assert.equal(sent, 0);
assert.equal(result().status, 'error');
assert.ok(result().message.includes('方向'));
''',
          );
        }
      }
    },
  );

  test(
    'rejected wrong-target writes remain blocked on website retries',
    () async {
      for (final fixture in <(String, String, Map<String, String>)>[
        (
          'follow',
          'user/follow',
          <String, String>{'target_user_id': 'wrong-profile'},
        ),
        (
          'commentLike',
          'comment/like',
          <String, String>{'note_id': 'note-1', 'comment_id': 'wrong-comment'},
        ),
        (
          'comment',
          'comment/post',
          <String, String>{'note_id': 'note-1', 'content': '另一条草稿'},
        ),
        ('like', 'note/like', <String, String>{'note_id': 'wrong-note'}),
      ]) {
        await _runJavaScript(
          r'''
let sent = 0;
window.fetch = async () => { sent++; return new Response('{}'); };
''' +
              _observe(
                action: fixture.$1,
                value: true,
                profileId: 'profile-1',
                targetId: fixture.$1 == 'commentLike' ? 'comment-1' : '',
              ) +
              'const args = [' +
              jsonEncode('/api/sns/web/v1/${fixture.$2}') +
              ', {method: "POST", body: ' +
              jsonEncode(jsonEncode(fixture.$3)) +
              r'''}];
await assert.rejects(window.fetch(...args));
assert.equal(result().status, 'error');
await assert.rejects(window.fetch(...args));
assert.equal(sent, 0);
''',
        );
      }
    },
  );

  test('unreadable Request bodies fail without sending or hanging', () async {
    for (final synchronous in <bool>[true, false]) {
      await _runJavaScript(
        'const synchronous = $synchronous;\n' +
            r'''
let sent = 0;
window.fetch = async () => { sent++; return new Response('{}'); };
''' +
            _observe(action: 'follow', value: true, profileId: 'profile-1') +
            r'''
const request = {
  method: 'POST', url: 'https://edith.xiaohongshu.com/api/sns/web/v1/user/follow',
  clone() {
    if (synchronous) throw new Error('Body already used');
    return {text: async () => { throw new Error('Body unreadable'); }};
  }
};
await assert.rejects(window.fetch(request));
assert.equal(sent, 0);
assert.equal(result().status, 'error');
assert.ok(result().message.includes('无法读取'));
''',
      );
    }
  });

  test(
    'follow and comment likes reject server refusal and network ambiguity',
    () async {
      for (final action in <String>['follow', 'commentLike']) {
        for (final networkFailure in <bool>[false, true]) {
          final body = action == 'follow'
              ? <String, String>{'target_user_id': 'profile-1'}
              : <String, String>{
                  'note_id': 'note-1',
                  'comment_id': 'comment-1',
                };
          await _runJavaScript(
            'const networkFailure = $networkFailure;\n' +
                r'''
let sent = 0;
window.fetch = async () => {
  sent++;
  if (networkFailure) throw new Error('connection lost');
  return new Response(JSON.stringify({success: false, msg: '请先登录'}));
};
''' +
                _observe(
                  action: action,
                  value: true,
                  profileId: 'profile-1',
                  targetId: 'comment-1',
                ) +
                'const args = [' +
                jsonEncode(
                  '/api/sns/web/v1/${action == 'follow' ? 'user/follow' : 'comment/like'}',
                ) +
                ', {method: "POST", body: ' +
                jsonEncode(jsonEncode(body)) +
                r'''}];
const request = window.fetch(...args);
if (networkFailure) await assert.rejects(request); else await request;
await tick();
assert.equal(result().status, networkFailure ? 'unknown' : 'error');
await assert.rejects(window.fetch(...args));
assert.equal(sent, 1);
''',
          );
        }
      }
    },
  );

  test(
    'verification and throttling responses offer actionable guidance',
    () async {
      for (final status in <int>[429, 461, 471]) {
        await _runJavaScript(
          'window.fetch = async () => new Response("", {status: $status});\n' +
              _observe(action: 'follow', value: true, profileId: 'profile-1') +
              r'''
await window.fetch('/api/sns/web/v1/user/follow', {
  method: 'POST', body: '{"target_user_id":"profile-1"}'
});
await tick();
assert.equal(result().status, 'error');
''' +
              'assert.ok(result().message.includes(' +
              jsonEncode(status == 429 ? '稍后' : '验证') +
              '));',
        );
      }
    },
  );

  test(
    'wrong reply targets, text and notes are blocked before sending',
    () async {
      for (final body in <Map<String, String>>[
        <String, String>{'note_id': 'note-1', 'content': '同一条评论'},
        <String, String>{
          'note_id': 'wrong-note',
          'content': '同一条评论',
          'target_comment_id': 'reply-target',
        },
        <String, String>{
          'note_id': 'note-1',
          'content': '另一条草稿',
          'target_comment_id': 'reply-target',
        },
      ]) {
        await _runJavaScript(
          r'''
let sent = 0;
window.fetch = async () => { sent++; return new Response('{}'); };
''' +
              _observe(targetId: 'reply-target') +
              'await assert.rejects(window.fetch("/api/sns/web/v1/comment/post", {method: "POST", body: ' +
              jsonEncode(jsonEncode(body)) +
              r'''}));
assert.equal(sent, 0);
assert.equal(result().status, 'error');
''',
        );
      }
    },
  );

  test(
    'Request inputs preserve exact nested targets and escaped content',
    () async {
      const content = '换行\n"引号" \\ 路径';
      await _runJavaScript(
        r'''
window.fetch = async () => new Response(JSON.stringify({success: true}));
''' +
            _observe(targetId: 'nested-2', content: content) +
            'await window.fetch(new Request("https://edith.xiaohongshu.com/api/sns/web/v1/comment/post", {method: "POST", body: ' +
            jsonEncode(
              jsonEncode(<String, String>{
                'note_id': 'note-1',
                'content': content,
                'target_comment_id': 'nested-2',
              }),
            ) +
            r'''}));
await tick();
assert.equal(result().status, 'success');
''',
      );
    },
  );

  test('retries remain blocked after network failure and timeout', () async {
    for (final failure in <bool>[true, false]) {
      await _runJavaScript(
        'const networkFailure = ' +
            failure.toString() +
            r''';
let sent = 0;
window.fetch = async () => {
  sent++;
  if (networkFailure) throw new Error('connection lost');
  return new Promise(() => {});
};
''' +
            _observe() +
            r'''
const args = ['/api/sns/web/v1/comment/post', {
  method: 'POST', body: JSON.stringify({note_id: 'note-1', content: '同一条评论'})
}];
const first = window.fetch(...args);
if (networkFailure) await assert.rejects(first);
window.__mixsocialXhsInteraction.cancel('operation-1');
assert.equal(result().status, 'unknown');
await assert.rejects(window.fetch(...args));
assert.equal(sent, 1);
assert.equal(window.__mixsocialXhsInteraction.begin({id: 'operation-1'}), false);
''',
      );
    }
  });

  test(
    'HTTP failures and unconfirmed successful HTTP responses differ',
    () async {
      for (final status in <int>[200, 403, 500]) {
        await _runJavaScript(
          'window.fetch = async () => new Response("<html>unavailable</html>", {status: ' +
              status.toString() +
              '});\n' +
              _observe() +
              r'''
await window.fetch('/api/sns/web/v1/comment/post', {
  method: 'POST', body: JSON.stringify({note_id: 'note-1', content: '同一条评论'})
});
await tick();
''' +
              'assert.equal(result().status, ' +
              jsonEncode(status == 200 ? 'unknown' : 'error') +
              ');\nassert.equal(result().httpStatus, ' +
              status.toString() +
              ');',
        );
      }
    },
  );

  test(
    'XHR handles success, refusal and network loss without retrying',
    () async {
      for (final fixture in <(int, Map<String, Object>, String)>[
        (200, <String, Object>{'success': true, 'code': 0}, 'success'),
        (200, <String, Object>{'success': false, 'msg': '操作频繁'}, 'error'),
        (0, <String, Object>{}, 'unknown'),
      ]) {
        await _runJavaScript(
          r'''
global.XMLHttpRequest = class extends EventTarget {
  open(method, url) {}
  send(body) {
    this.responseType = 'json';
''' +
              'this.status = ' +
              fixture.$1.toString() +
              ';\n' +
              'this.response = ' +
              jsonEncode(fixture.$2) +
              ';\n' +
              r'''
    this.dispatchEvent(new Event('loadend'));
  }
};
delete window.fetch;
''' +
              _observe() +
              r'''
const xhr = new XMLHttpRequest();
xhr.open('POST', '/api/sns/web/v1/comment/post');
xhr.send(JSON.stringify({note_id: 'note-1', content: '同一条评论'}));
''' +
              'assert.equal(result().status, ' +
              jsonEncode(fixture.$3) +
              ');',
        );
      }
    },
  );

  test(
    'Vue ref booleans are read without assuming unknown means false',
    () async {
      await _runJavaScript(
        r'''
window.__INITIAL_STATE__ = {note: {value: {noteDetailMap: {_value: {
  'note-1': {note: {interactInfo: {value: {liked: {value: false}, collected: true}}}}
}}}}};
''' +
            'assert.equal(' +
            xhsCurrentInteractionStateScript('note-1', 'liked') +
            ', "false");\n' +
            'assert.equal(' +
            xhsCurrentInteractionStateScript('note-1', 'collected') +
            ', "true");\n' +
            'assert.equal(' +
            xhsCurrentInteractionStateScript('missing', 'liked') +
            ', "");',
      );
    },
  );

  test(
    'profile follow controls ignore unrelated accounts and wrong pages',
    () async {
      await _runJavaScript(
        r'''
location.href = 'https://www.xiaohongshu.com/user/profile/profile-1?xsec_token=fixture';
let clicked = 0;
const button = {
  textContent: ' 关 注 ',
  getAttribute: () => null,
  closest: () => null,
  click: () => { clicked++; }
};
const recommendation = {...button, textContent: '已关注', closest: (selector) =>
  selector.includes('.recommend-user') ? {} : null};
const header = {querySelectorAll: () => [button, recommendation]};
global.document = {querySelectorAll: () => [header, header]};
''' +
            'assert.equal(' +
            xhsFollowStateScript('profile-1') +
            ', "false");\n' +
            'assert.equal(' +
            xhsFollowStateScript('other-profile') +
            ', "");\n' +
            'assert.equal(' +
            xhsClickFollowScript(true, 'other-profile') +
            ', false);\n' +
            'assert.equal(' +
            xhsClickFollowScript(false, 'profile-1') +
            ', false);\n' +
            'assert.equal(' +
            xhsClickFollowScript(true, 'profile-1') +
            r''', true);
assert.equal(clicked, 1);
button.textContent = '互相关注';
''' +
            'assert.equal(' +
            xhsFollowStateScript('profile-1') +
            ', "true");\n' +
            'location.href = "https://www.xiaohongshu.com/explore/profile-1";\n' +
            'assert.equal(' +
            xhsFollowStateScript('profile-1') +
            ', "");',
      );
    },
  );

  test('missing, ambiguous or disabled follow controls stay unknown', () async {
    await _runJavaScript(
      r'''
location.href = 'https://www.xiaohongshu.com/user/profile/profile-1';
const button = {textContent: '关注', getAttribute: () => null, closest: () => null};
let buttons = [];
global.document = {querySelectorAll: () => [{querySelectorAll: () => buttons}]};
''' +
          'const state = () => ' +
          xhsFollowStateScript('profile-1') +
          ';\nconst click = () => ' +
          xhsClickFollowScript(true, 'profile-1') +
          r''';
assert.equal(state(), '');
assert.equal(click(), false);
buttons = [button, {...button, textContent: '已关注'}];
assert.equal(state(), '');
assert.equal(click(), false);
buttons = [{...button, disabled: true}];
assert.equal(state(), '');
buttons = [{...button, getAttribute: () => 'true'}];
assert.equal(state(), '');
buttons = [{...button, closest: () => ({})}];
assert.equal(state(), '');
''',
    );
  });

  test(
    'unfollow confirmation is scoped and never clicks after sending',
    () async {
      await _runJavaScript(
        r'''
let clicked = 0;
const button = {
  textContent: '确定', getAttribute: () => null, closest: () => null,
  click: () => { clicked++; }
};
let dialogs = [{textContent: '退出登录', querySelectorAll: () => [button]}];
global.document = {querySelectorAll: () => dialogs};
window.__mixsocialXhsInteraction = {pending: {
  action: 'follow', value: false, status: 'pending', sent: false
}};
''' +
            'const confirm = () => ' +
            xhsConfirmUnfollowScript +
            r''';
assert.equal(confirm(), false);
dialogs = [{textContent: '确定取消关注吗？', querySelectorAll: () => [button]}];
window.__mixsocialXhsInteraction.pending.sent = true;
assert.equal(confirm(), false);
window.__mixsocialXhsInteraction.pending.sent = false;
window.__mixsocialXhsInteraction.pending.status = 'unknown';
assert.equal(confirm(), false);
window.__mixsocialXhsInteraction.pending.status = 'pending';
assert.equal(confirm(), true);
assert.equal(clicked, 1);
''',
      );
    },
  );

  test('XHR verifies profile and comment targets as strictly as fetch', () async {
    for (final action in <String>['follow', 'commentLike']) {
      await _runJavaScript(
        r'''
let sent = 0;
global.XMLHttpRequest = class extends EventTarget {
  open(method, url) {}
  send(body) {
    sent++;
    this.status = 200;
    this.responseType = 'json';
    this.response = {success: true};
    this.dispatchEvent(new Event('loadend'));
  }
};
delete window.fetch;
''' +
            _observe(
              action: action,
              value: true,
              profileId: 'profile-1',
              targetId: 'comment-1',
            ) +
            'const endpoint = ' +
            jsonEncode(
              '/api/sns/web/v1/${action == 'follow' ? 'user/follow' : 'comment/like'}',
            ) +
            ';\nconst body = ' +
            jsonEncode(
              jsonEncode(
                action == 'follow'
                    ? <String, String>{'target_user_id': 'profile-1'}
                    : <String, String>{
                        'note_id': 'note-1',
                        'comment_id': 'comment-1',
                      },
              ),
            ) +
            r''';
const xhr = new XMLHttpRequest();
xhr.open('POST', endpoint);
xhr.send(body);
assert.equal(result().status, 'success');
const duplicate = new XMLHttpRequest();
duplicate.open('POST', endpoint);
assert.throws(() => duplicate.send(body));
assert.equal(sent, 1);
''',
      );
    }
  });
}
