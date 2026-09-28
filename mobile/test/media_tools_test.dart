import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/media_tools.dart';
import 'package:mixsocial_mobile/src/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('image downloader enforces platform-specific HTTPS domains', () {
    expect(
      isSupportedDownloadUrl(
        'https://sns-webpic.xhscdn.com/a.jpg',
        SourceId.xhs,
      ),
      true,
    );
    expect(
      isSupportedDownloadUrl(
        'https://tiebapic.baidu.com/a.jpg',
        SourceId.tieba,
      ),
      true,
    );
    expect(
      isSupportedDownloadUrl(
        'https://picx.zhimg.com/a.jpg',
        SourceId.zhihu,
      ),
      true,
    );
    expect(
      isSupportedDownloadUrl(
        'https://picx.zhimg.com.evil.example/a.jpg',
        SourceId.zhihu,
      ),
      false,
    );
    for (final value in [
      'http://sns-webpic.xhscdn.com/a',
      'https://sns-webpic.xhscdn.com.evil.example/a',
      'https://u:p@sns-webpic.xhscdn.com/a',
      'https://sns-webpic.xhscdn.com:444/a',
      'file:///tmp/a',
      'https://127.0.0.1/a',
      'https://tiebapic.baidu.com/a',
    ]) {
      expect(isSupportedDownloadUrl(value, SourceId.xhs), false, reason: value);
    }
  });

  test(
    'user initiated media operation sends only URLs and source, no account state',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(MediaTools.channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(MediaTools.channel, null),
      );
      await MediaTools.image(
        const MediaItem(
          kind: 'image',
          url: 'https://sns-webpic.xhscdn.com/a.jpg!nd_dft_webp_3',
        ),
        SourceId.xhs,
        save: true,
      );
      expect(calls.single.method, 'saveImage');
      final arguments = calls.single.arguments as Map;
      expect(arguments.keys.toSet(), {'source', 'urls'});
      expect(arguments['urls'], [
        'https://sns-webpic.xhscdn.com/a.jpg',
        'https://sns-webpic.xhscdn.com/a.jpg!nd_dft_webp_3',
      ]);
      await expectLater(
        MediaTools.image(
          const MediaItem(kind: 'image', url: 'https://evil.example/a'),
          SourceId.xhs,
          save: false,
        ),
        throwsFormatException,
      );
      expect(calls, hasLength(1));
    },
  );

  test('text and backup file share validate before invoking native', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(MediaTools.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(MediaTools.channel, null),
    );
    await MediaTools.shareText('https://tieba.baidu.com/p/42');
    await MediaTools.shareTextFile('{}', fileName: 'mixsocial-library.json');
    expect(calls.map((call) => call.method), ['shareText', 'shareTextFile']);
    await expectLater(MediaTools.shareText(' '), throwsFormatException);
    await expectLater(
      MediaTools.shareTextFile('{}', fileName: '../private.json'),
      throwsFormatException,
    );
    await expectLater(
      MediaTools.shareTextFile(
        '{}',
        fileName: 'safe.json',
        mimeType: 'application/octet-stream',
      ),
      throwsFormatException,
    );
    expect(calls, hasLength(2));
  });
}
