import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/content_links.dart';
import 'package:mixsocial_mobile/src/media_tools.dart';
import 'package:mixsocial_mobile/src/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = '1234567890abcdef12345678';

  test('extracts pasted share text, excludes unknown hosts and deduplicates', () {
    final links = extractContentLinks(
      '文字 https://tieba.baidu.com/p/123。 https://evil.example/ https://tieba.baidu.com/p/123',
    );
    expect(links.map((uri) => uri.host), ['tieba.baidu.com']);
    expect(contentRefFromUri(links.single)?.id, '123');
  });

  test('canonicalizes supported note paths and preserves only note token', () {
    for (final path in ['/explore/$id', '/discovery/item/$id']) {
      final ref = contentRefFromUri(
        Uri.parse(
          'http://www.xiaohongshu.com$path?xsec_token=a%2Bb%3D&redirect=https://evil.example',
        ),
      )!;
      expect(ref.source, SourceId.xhs);
      expect(ref.token, 'a+b=');
      final uri = Uri.parse(ref.url);
      expect(uri.scheme, 'https');
      expect(uri.path, '/explore/$id');
      expect(uri.queryParameters['xsec_token'], 'a+b=');
      expect(uri.queryParameters.containsKey('redirect'), false);
    }
  });

  test('recognizes Zhihu questions answers articles and pins', () {
    final answer = contentRefFromUri(
      Uri.parse('https://www.zhihu.com/question/123/answer/456?utm_source=x'),
    )!;
    expect(answer.source, SourceId.zhihu);
    expect(answer.id, '456');
    expect(answer.parentId, '123');
    expect(answer.token, 'answer');
    expect(answer.url, 'https://www.zhihu.com/question/123/answer/456');

    for (final entry in <(String, String)>[
      ('https://zhihu.com/question/123', 'question'),
      ('https://www.zhihu.com/pin/789', 'pin'),
      ('https://zhuanlan.zhihu.com/p/321', 'article'),
    ]) {
      final ref = contentRefFromUri(Uri.parse(entry.$1))!;
      expect(ref.source, SourceId.zhihu);
      expect(ref.token, entry.$2);
    }
  });

  test(
    'malicious URL forms and unknown source paths never become content refs',
    () {
      for (final url in [
        'javascript:alert(1)',
        'file:///p/123',
        'https://tieba.baidu.com.evil.example/p/123',
        'https://tieba.baidu.com@evil.example/p/123',
        'https://evil.example@tieba.baidu.com/p/123',
        'https://tieba.baidu.com:444/p/123',
        'https://127.0.0.1/p/123',
        'https://www.xiaohongshu.com/explore/not-an-id',
        'https://tieba.baidu.com/p/0',
        'https://tieba.baidu.com/p/123/extra',
        'https://www.xiaohongshu.com/explore/$id?xsec_token=%00x',
        'https://www.xiaohongshu.com/user/profile/$id',
        'https://www.zhihu.com/question/not-a-number',
        'https://evil.zhihu.com/question/123',
      ]) {
        expect(contentRefFromUri(Uri.parse(url)), null, reason: url);
      }
    },
  );

  test('bounds pasted text and extracted URLs', () {
    expect(extractContentLinks('x' * 65537), isEmpty);
    expect(
      extractContentLinks(
        List.generate(
          20,
          (i) => 'https://tieba.baidu.com/p/${i + 1}',
        ).join(' '),
      ),
      hasLength(8),
    );
  });

  test(
    'direct link is local-only; unsupported link never reaches native',
    () async {
      var calls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(MediaTools.channel, (_) async {
        calls++;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(MediaTools.channel, null),
      );
      expect(
        (await resolveContentLink(
          Uri.parse('https://tieba.baidu.com/p/42'),
        )).id,
        '42',
      );
      await expectLater(
        resolveContentLink(Uri.parse('https://evil.example/p/42')),
        throwsFormatException,
      );
      expect(calls, 0);
    },
  );

  test('short-link resolver revalidates redirect destination', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var target = 'https://www.xiaohongshu.com/explore/$id?xsec_token=token';
    messenger.setMockMethodCallHandler(MediaTools.channel, (call) async {
      expect(call.method, 'resolveLink');
      return target;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(MediaTools.channel, null),
    );
    expect(
      (await resolveContentLink(Uri.parse('https://xhslink.com/a/abc'))).token,
      'token',
    );
    target = 'https://evil.example/explore/$id';
    await expectLater(
      resolveContentLink(Uri.parse('https://xhslink.com/a/abc')),
      throwsFormatException,
    );
  });

  test(
    'cold/hot incoming link events deduplicate by event ID, not URL',
    () async {
      const channel = MethodChannel('mixsocial/test_links');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final cold = {'id': 'cold', 'text': 'https://tieba.baidu.com/p/42'};
      messenger.setMockMethodCallHandler(channel, (_) async => cold);
      final receiver = IncomingLinkReceiver(channel: channel);
      final received = <IncomingContentLink>[];
      final subscription = receiver.events.listen(received.add);
      addTearDown(() async {
        await subscription.cancel();
        receiver.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      await receiver.start();
      Future<void> emit(Object? value) async {
        final done = Completer<void>();
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('incomingLink', value),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await Future<void>.delayed(Duration.zero);
      }

      await emit(cold);
      await emit({'id': 'hot', 'text': cold['text']});
      await emit({'id': '', 'text': 'invalid'});
      await emit({'id': 'long', 'text': 'x' * 65537});
      await emit(null);
      expect(received.map((event) => event.id), ['cold', 'hot']);
    },
  );
}
