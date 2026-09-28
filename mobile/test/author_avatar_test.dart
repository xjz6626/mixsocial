import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/feed_widgets.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/network_media.dart';

const _channel = MethodChannel('mixsocial/core');
const _avatar = 'https://sns-avatar-qc.xhscdn.com/avatar/example.jpg';
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQAB'
  'DQottAAAAABJRU5ErkJggg==',
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test(
    'author accepts alternate avatar fields without stringifying objects',
    () {
      final author = Author.fromJson(<String, Object?>{
        'id': 'a',
        'name': '作者',
        'avatar': <String, Object?>{},
        'image': <String, Object?>{'url': _avatar},
        'images': <Object?>[
          <String, Object?>{'url': '$_avatar?size=80'},
          _avatar,
        ],
      }, SourceId.xhs);

      expect(author.avatar, _avatar);
      expect(author.avatarUrls, <String>['$_avatar?size=80']);
      final restored = Author.fromJson(author.toJson(), SourceId.xhs);
      expect(restored.avatar, author.avatar);
      expect(restored.avatarUrls, author.avatarUrls);
      expect(author.copyWith(name: '另一位作者').avatarUrls, author.avatarUrls);
      expect(author.copyWith(avatar: '$_avatar?updated=1').avatarUrls, isEmpty);
    },
  );

  test('avatar candidates reject bad URLs and retain CDN query parameters', () {
    final author = Author.fromJson(<String, Object?>{
      'avatar': '[object Object]',
      'avatar_urls': <String>[
        'data:image/png;base64,abc',
        '//sns-avatar-qc.xhscdn.com/avatar/a.jpg?imageView2/2/w/80&token=abc',
        'https://sns-avatar-qc.xhscdn.com/avatar/a.jpg?imageView2/2/w/80&token=abc',
      ],
    }, SourceId.xhs);

    expect(avatarImageCandidates(author), <String>[
      'https://sns-avatar-qc.xhscdn.com/avatar/a.jpg?imageView2/2/w/80&token=abc',
    ]);
  });

  test('profile preserves alternate avatars for its header', () {
    final profile = ProfilePage.fromJson(<String, Object?>{
      'ref': <String, Object?>{'source': 'xhs', 'id': 'a'},
      'name': '作者',
      'avatar': _avatar,
      'avatar_urls': <String>[_avatar, '$_avatar?backup=profile'],
    });

    expect(profile.avatar, _avatar);
    expect(profile.avatarUrls, <String>['$_avatar?backup=profile']);
  });

  group('native avatar loading', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if ((call.arguments as Map)['url'].toString().contains('missing')) {
              throw PlatformException(code: 'IMAGE_DOWNLOAD_FAILED');
            }
            return _png;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    testWidgets('avatar passes available alternate URLs to the image loader', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const AuthorAvatar(
            author: Author(
              ref: ProfileRef(source: SourceId.xhs, id: 'a'),
              id: 'a',
              name: '作者',
              avatar: '$_avatar?author=1',
              avatarUrls: <String>['$_avatar?author=2'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final loader = tester.widget<SourceNetworkImage>(
        find.byType(SourceNetworkImage),
      );
      expect(loader.fallbackUrls, <String>['$_avatar?author=2']);
      expect(calls.single.method, 'media.fetchImage');
      expect(
        (calls.single.arguments as Map)['headers']['Referer'],
        'https://www.xiaohongshu.com/',
      );
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('valid backup loads even when the primary URL is invalid', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SourceNetworkImage(
            url: '[object Object]',
            fallbackUrls: <String>['$_avatar?invalid-main=1'],
            source: SourceId.xhs,
            width: 32,
            height: 32,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls.single.arguments['url'], '$_avatar?invalid-main=1');
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a failed CDN URL falls through to the supplied backup', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SourceNetworkImage(
            url: '$_avatar?missing=1',
            fallbackUrls: <String>['$_avatar?backup=1'],
            source: SourceId.xhs,
            width: 32,
            height: 32,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls.map((call) => call.arguments['url']), <String>[
        '$_avatar?missing=1',
        '$_avatar?missing=1',
        '$_avatar?backup=1',
      ]);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets(
      'native cache separates sources with different request headers',
      (tester) async {
        await tester.pumpWidget(
          _host(
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SourceNetworkImage(
                  url: '$_avatar?source-cache=1',
                  source: SourceId.xhs,
                  width: 32,
                  height: 32,
                ),
                SourceNetworkImage(
                  url: '$_avatar?source-cache=1',
                  source: SourceId.tieba,
                  width: 32,
                  height: 32,
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(calls, hasLength(2));
        expect(
          calls.map((call) => call.arguments['headers']['Referer']).toSet(),
          <String>{'https://www.xiaohongshu.com/', 'https://tieba.baidu.com/'},
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  });
}
