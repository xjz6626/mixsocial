import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/xhs_account_scripts.dart';

void main() {
  test('current account comes from userInfo, not the viewed profile', () async {
    final result = await _read(<String, Object?>{
      'user': <String, Object?>{
        'userInfo': <String, Object?>{
          'value': <String, Object?>{
            'user_id': 'signed-in-id',
            'nickname': '我的昵称',
            'guest': false,
            'image': <String, Object?>{'url': '//sns-avatar.xhscdn.com/me'},
          },
        },
        'userPageData': <String, Object?>{
          'basicInfo': <String, Object?>{
            'userId': 'someone-else',
            'nickname': '其他作者',
          },
        },
      },
    });

    expect(result['id'], 'signed-in-id');
    expect(result['name'], '我的昵称');
    expect(result['avatar'], '//sns-avatar.xhscdn.com/me');
    expect(result['ref']['url'], contains('/user/profile/signed-in-id'));
  });

  test('nested root and user refs are unwrapped', () async {
    final result = await _read(<String, Object?>{
      '_rawValue': <String, Object?>{
        'user': <String, Object?>{
          'value': <String, Object?>{
            'userInfo': <String, Object?>{
              '_value': <String, Object?>{'userId': 'me'},
            },
          },
        },
      },
    });
    expect(result['id'], 'me');
  });

  test(
    'an exact sidebar me link is a safe fallback and retains its token',
    () async {
      final result = await _read(
        const <String, Object?>{},
        links: <Map<String, String>>[
          <String, String>{
            'text': ' 我 ',
            'href': '/user/profile/my-id?xsec_token=my-token&tab=fav',
          },
        ],
      );
      expect(result['id'], 'my-id');
      expect(result['ref']['token'], 'my-token');
      expect(result['ref']['url'], isNot(contains('tab=')));
    },
  );

  test('guest state overrides a stale sidebar account link', () async {
    for (final guest in <Object>[true, 'true', 1]) {
      final result = await _read(
        <String, Object?>{
          'user': <String, Object?>{
            'userInfo': <String, Object?>{'userId': 'guest-id', 'guest': guest},
          },
        },
        links: <Map<String, String>>[
          <String, String>{'text': '我', 'href': '/user/profile/stale-user'},
        ],
      );
      expect(result, isEmpty);
    }
  });

  test(
    'missing IDs, invalid IDs and viewed profile data do not imply login',
    () async {
      for (final state in <Map<String, Object?>>[
        <String, Object?>{
          'user': <String, Object?>{
            'userInfo': <String, Object?>{'nickname': '昵称不等于身份'},
          },
        },
        <String, Object?>{
          'user': <String, Object?>{
            'userInfo': <String, Object?>{'userId': '../invalid'},
          },
        },
        <String, Object?>{
          'user': <String, Object?>{
            'userPageData': <String, Object?>{
              'basicInfo': <String, Object?>{'userId': 'viewed-user'},
            },
          },
        },
      ]) {
        expect(await _read(state), isEmpty);
      }
    },
  );

  test(
    'author links, external URLs and conflicting identities are rejected',
    () async {
      for (final link in <Map<String, String>>[
        <String, String>{'text': '作者', 'href': '/user/profile/author'},
        <String, String>{
          'text': '我',
          'href': 'https://example.invalid/user/profile/me',
        },
        <String, String>{
          'text': '我',
          'href': 'http://www.xiaohongshu.com/user/profile/me',
        },
        <String, String>{
          'text': '我',
          'href': 'https://user:pass@www.xiaohongshu.com/user/profile/me',
        },
      ]) {
        expect(
          await _read(
            const <String, Object?>{},
            links: <Map<String, String>>[link],
          ),
          isEmpty,
        );
      }
      expect(
        await _read(
          <String, Object?>{
            'user': <String, Object?>{
              'userInfo': <String, Object?>{'userId': 'state-account'},
            },
          },
          links: <Map<String, String>>[
            <String, String>{
              'text': '我',
              'href': '/user/profile/different-account',
            },
          ],
        ),
        isEmpty,
      );
    },
  );
}

Future<Map<String, dynamic>> _read(
  Map<String, Object?> state, {
  List<Map<String, String>> links = const <Map<String, String>>[],
}) async {
  final program =
      '''
global.window = {__INITIAL_STATE__: ${jsonEncode(state)}};
global.location = {href: 'https://www.xiaohongshu.com/user/profile/not-me'};
const nodes = ${jsonEncode(links)}.map(link => ({
  textContent: link.text,
  getAttribute: name => name === 'href' ? link.href : null,
  closest: () => null,
}));
global.document = {querySelectorAll: selector => {
  if (selector !== '.main-container .user .link-wrapper') throw new Error('Identity must use the scoped me link');
  return nodes;
}};
const value = eval(${jsonEncode(xhsCurrentProfileScript)});
process.stdout.write(value || '{}');
''';
  final result = await Process.run('node', <String>['-e', program]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}
