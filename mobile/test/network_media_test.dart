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
    expect(
      mediaRequestHeaders(SourceId.zhihu)['Referer'],
      'https://www.zhihu.com/',
    );
    expect(mediaRequestHeaders(SourceId.all).containsKey('Referer'), isFalse);
    expect(
      mediaRequestHeaders(SourceId.xhs, video: true)['Accept'],
      contains('video/*'),
    );
  });

  test('builds a safe original XHS candidate without CDN resize suffix', () {
    const transformed =
        'http://sns-webpic-qc.xhscdn.com/notes/image.jpg!nd_dft_wlteh_webp_3?token=abc';
    expect(
      xhsOriginalImageUrl(transformed),
      'https://sns-webpic-qc.xhscdn.com/notes/image.jpg?token=abc',
    );
    expect(
      xhsOriginalImageUrl('https://example.com/image.jpg!nd_dft_webp_3'),
      'https://example.com/image.jpg!nd_dft_webp_3',
    );
    expect(
      xhsOriginalImageUrl(
        'https://sns-webpic.xhscdn.com/image.jpg!custom_signature',
      ),
      'https://sns-webpic.xhscdn.com/image.jpg!custom_signature',
    );
  });

  test('orders thumbnail, detail and original candidates by use case', () {
    const media = MediaItem(
      kind: 'image',
      url: 'https://sns-webpic.xhscdn.com/image.jpg!nd_dft_webp_3',
      previewUrl: 'https://sns-webpic.xhscdn.com/image.jpg!nd_prv_webp_3',
    );
    expect(
      mediaImageCandidates(media, SourceId.xhs, MediaImageQuality.thumbnail),
      <String>[media.previewUrl, media.url],
    );
    expect(
      mediaImageCandidates(media, SourceId.xhs, MediaImageQuality.detail),
      <String>[media.url, media.previewUrl],
    );
    expect(
      mediaImageCandidates(media, SourceId.xhs, MediaImageQuality.original),
      <String>[
        'https://sns-webpic.xhscdn.com/image.jpg',
        media.url,
        media.previewUrl,
      ],
    );
  });
}
