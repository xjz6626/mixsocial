import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/zhihu_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixsocial/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  String stateResponse = '{"following":false}';
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    calls = [];
    stateResponse = '{"following":false}';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method.endsWith('.following') ||
          call.method.endsWith('.forumFollowing')) {
        return stateResponse;
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native author and forum actions pass explicit targets, directions and cancellable request IDs',
    () async {
      final tieba = await TiebaSource.create();
      final zhihu = await ZhihuSource.create();
      const tiebaAuthor = ProfileRef(source: SourceId.tieba, id: '42');
      const zhihuAuthor = ProfileRef(
        source: SourceId.zhihu,
        id: 'hash-id',
        token: 'alice',
      );
      expect(tieba.capabilities, contains(SourceCapability.follow));
      expect(zhihu.capabilities, contains(SourceCapability.follow));
      await tieba.follow(tiebaAuthor, true);
      await tieba.follow(tiebaAuthor, false);
      expect(await tieba.following(tiebaAuthor), isFalse);
      await zhihu.follow(zhihuAuthor, true);
      await zhihu.follow(zhihuAuthor, false);
      expect(await zhihu.following(zhihuAuthor), isFalse);
      await tieba.followForum(' Golang吧 ', true);
      await tieba.followForum('golang', false);
      expect(await tieba.forumFollowing('Golang吧'), isFalse);
      final operations = calls
          .where((call) => !call.method.endsWith('.configure'))
          .toList();
      expect(operations.map((call) => call.method), [
        'tieba.follow',
        'tieba.follow',
        'tieba.following',
        'zhihu.follow',
        'zhihu.follow',
        'zhihu.following',
        'tieba.followForum',
        'tieba.followForum',
        'tieba.forumFollowing',
      ]);
      expect(
        operations.map((call) => (call.arguments as Map)['requestId']).toSet(),
        hasLength(9),
      );
      for (final call in operations) {
        final arguments = call.arguments as Map;
        expect(arguments['requestId'], isNotEmpty);
        if (arguments.containsKey('ref')) {
          final ref = jsonDecode(arguments['ref'] as String) as Map;
          expect(ref['source'], call.method.split('.').first);
          expect(
            ref['id'],
            call.method.startsWith('tieba.') ? '42' : 'hash-id',
          );
        } else {
          expect(arguments['forum'], 'golang');
        }
      }
      expect((operations[0].arguments as Map)['value'], true);
      expect((operations[1].arguments as Map)['value'], false);
      expect((operations[4].arguments as Map)['value'], false);
      expect((operations[7].arguments as Map)['value'], false);
    },
  );

  test(
    'missing, non-boolean or rejected state responses never become a confirmed false',
    () async {
      final tieba = await TiebaSource.create();
      final zhihu = await ZhihuSource.create();
      for (final response in ['{}', '{"following":"false"}']) {
        stateResponse = response;
        await expectLater(
          tieba.following(const ProfileRef(source: SourceId.tieba, id: '42')),
          throwsStateError,
        );
        await expectLater(
          zhihu.following(
            const ProfileRef(source: SourceId.zhihu, id: 'alice'),
          ),
          throwsStateError,
        );
        await expectLater(tieba.forumFollowing('golang'), throwsStateError);
      }
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: '401', message: '登录已失效'),
      );
      await expectLater(
        tieba.follow(const ProfileRef(source: SourceId.tieba, id: '42'), true),
        throwsException,
      );
      await expectLater(
        zhihu.follow(
          const ProfileRef(source: SourceId.zhihu, id: 'alice'),
          true,
        ),
        throwsException,
      );
    },
  );

  test(
    'invalid source and anonymous identities never reach the native channel',
    () async {
      final tieba = await TiebaSource.create();
      final zhihu = await ZhihuSource.create();
      calls.clear();
      await expectLater(
        tieba.follow(const ProfileRef(source: SourceId.zhihu, id: '42'), true),
        throwsArgumentError,
      );
      await expectLater(
        tieba.follow(const ProfileRef(source: SourceId.tieba, id: '0'), true),
        throwsArgumentError,
      );
      await expectLater(
        zhihu.follow(const ProfileRef(source: SourceId.tieba, id: '42'), false),
        throwsArgumentError,
      );
      await expectLater(
        zhihu.follow(const ProfileRef(source: SourceId.zhihu, id: '000'), true),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );
}
