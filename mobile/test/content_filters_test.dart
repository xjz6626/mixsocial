import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/content_filters.dart';
import 'package:mixsocial_mobile/src/models.dart';

FeedItem item({
  SourceId source = SourceId.tieba,
  String title = '普通主题',
  String forum = 'golang吧',
  List<MediaItem> media = const <MediaItem>[],
}) => FeedItem(
  ref: ContentRef(source: source, id: '1'),
  title: title,
  author: Author(
    ref: ProfileRef(source: source, id: '2'),
    id: '2',
    name: '作者',
  ),
  stats: const ItemStats(),
  tags: <String>[forum],
  media: media,
);

void main() {
  test('normalizes forum names with and without suffix', () {
    expect(normalizeForumName(' Golang吧 '), 'golang');
    expect(normalizeForumName('golang'), 'golang');
  });

  test('blocks matching Tieba forum but not an XHS tag', () {
    const filters = ContentFilters(blockedForums: <String>{'golang'});

    expect(filters.apply(<FeedItem>[item()]), isEmpty);
    expect(filters.apply(<FeedItem>[item(source: SourceId.xhs)]), hasLength(1));
  });

  test('keyword matching covers title and summary case-insensitively', () {
    const filters = ContentFilters(blockedKeywords: <String>{'spoiler'});
    expect(filters.apply(<FeedItem>[item(title: 'Contains SPOILER')]), isEmpty);
  });

  test('video hiding removes posts that contain video media', () {
    const filters = ContentFilters(hideVideos: true);
    final result = filters.apply(<FeedItem>[
      item(
        media: const <MediaItem>[
          MediaItem(kind: 'video', url: 'video'),
          MediaItem(kind: 'image', url: 'image'),
        ],
      ),
    ]);

    expect(result, isEmpty);
  });

  test('media hiding keeps text posts but removes all media', () {
    const filters = ContentFilters(hideMedia: true);
    final result = filters.apply(<FeedItem>[
      item(
        media: const <MediaItem>[
          MediaItem(kind: 'video', url: 'video'),
          MediaItem(kind: 'image', url: 'image'),
        ],
      ),
    ]);

    expect(result, hasLength(1));
    expect(result.single.media, isEmpty);
  });
}
