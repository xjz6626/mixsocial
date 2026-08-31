import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/network_media.dart';

void main() {
  test('normalizes protocol-relative and escaped media URLs', () {
    expect(
      normalizeMediaUrl('//sns-webpic.xhscdn.com/a.webp?x=1&amp;y=2'),
      'https://sns-webpic.xhscdn.com/a.webp?x=1&y=2',
    );
    expect(
      normalizeMediaUrl(r'https:\/\/imgsa.baidu.com\/forum\/pic.jpg'),
      'https://imgsa.baidu.com/forum/pic.jpg',
    );
  });

  test('rejects non-network media URLs', () {
    expect(mediaUri(''), isNull);
    expect(mediaUri('/relative/image.jpg'), isNull);
    expect(mediaUri('javascript:alert(1)'), isNull);
    expect(mediaUri('https://img.example/image.jpg')?.host, 'img.example');
    expect(
      mediaUri('http://video.example/clip.mp4', preferHttps: true)?.scheme,
      'https',
    );
  });

  test('uses source-specific anti-hotlink headers', () {
    expect(
      mediaRequestHeaders(SourceId.xhs)['Referer'],
      'https://www.xiaohongshu.com/',
    );
    expect(
      mediaRequestHeaders(SourceId.tieba)['Referer'],
      'https://tieba.baidu.com/',
    );
    expect(mediaRequestHeaders(SourceId.all).containsKey('Referer'), isFalse);
    expect(
      mediaRequestHeaders(SourceId.xhs, video: true)['Accept'],
      contains('video/*'),
    );
  });
}
