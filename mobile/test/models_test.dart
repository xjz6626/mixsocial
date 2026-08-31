import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/xhs_scripts.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';

void main() {
  test('decodes the Go mobile JSON field names', () {
    final page = FeedPage.decode(
      jsonEncode(<String, Object>{
        'items': <Object>[
          <String, Object>{
            'ref': <String, Object>{
              'source': 'tieba',
              'id': '42',
              'parentId': '7',
            },
            'title': '主题',
            'author': <String, Object>{
              'ref': <String, Object>{'source': 'tieba', 'id': '9'},
              'id': '9',
              'name': '作者',
            },
            'stats': <String, Object>{'likes': 12, 'comments': 3},
            'media': <Object>[
              <String, Object>{
                'kind': 'video',
                'previewUrl': 'https://example.invalid/cover.jpg',
                'duration': 2500000000,
              },
            ],
          },
        ],
        'nextCursor': 'next',
        'hasMore': true,
      }),
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.ref.source, SourceId.tieba);
    expect(page.items.single.ref.parentId, '7');
    expect(page.items.single.media.single.durationMilliseconds, 2500);
    expect(page.nextCursor, 'next');
    expect(page.hasMore, isTrue);
  });

  test('detail script preserves the feed token and escapes identifiers', () {
    const id = "note'with-special";
    const token = 'token\\with-special';
    final script = xhsDetailScript(id, token);

    expect(script, contains(jsonEncode(id)));
    expect(script, contains(jsonEncode(token)));
    expect(script, isNot(contains("map['$id']")));
    expect(script, contains('if (videoUrl) media = [{'));
    expect(script, isNot(contains('images.push')));
  });

  test('video display URL never treats the MP4 stream as an image', () {
    const withoutCover = MediaItem(
      kind: 'video',
      url: 'https://video.example/clip.mp4',
    );
    const withCover = MediaItem(
      kind: 'video',
      url: 'https://video.example/clip.mp4',
      previewUrl: 'https://image.example/cover.jpg',
    );

    expect(withoutCover.displayUrl, isEmpty);
    expect(withCover.displayUrl, 'https://image.example/cover.jpg');
  });

  test('profile keys remain source scoped', () {
    const xhs = ProfileRef(source: SourceId.xhs, id: 'same');
    const tieba = ProfileRef(source: SourceId.tieba, id: 'same');

    expect(xhs.key, 'xhs:same');
    expect(tieba.key, 'tieba:same');
    expect(xhs.key, isNot(tieba.key));
  });

  test('feed items round-trip through local cache JSON', () {
    final original = FeedItem(
      ref: const ContentRef(source: SourceId.tieba, id: '42'),
      title: '缓存主题',
      summary: '正文',
      author: const Author(
        ref: ProfileRef(source: SourceId.tieba, id: '9'),
        id: '9',
        name: '作者',
      ),
      publishedAt: DateTime.utc(2026, 8, 28),
      stats: const ItemStats(likes: 8),
      tags: const <String>['golang吧'],
      favorited: true,
    );

    final decoded = FeedItem.fromJson(original.toJson());
    expect(decoded.key, original.key);
    expect(decoded.forumName, 'golang');
    expect(decoded.publishedAt, original.publishedAt);
    expect(decoded.favorited, isTrue);
  });

  test('detail decodes pagination and nested replies', () {
    final detail = FeedDetail.decode(
      jsonEncode(<String, Object>{
        'ref': <String, Object>{'source': 'tieba', 'id': '42'},
        'title': '主题',
        'author': <String, Object>{'id': '9', 'name': '楼主'},
        'stats': <String, Object>{},
        'body': '主楼',
        'hasMore': true,
        'nextCursor': '2',
        'comments': <Object>[
          <String, Object>{
            'ref': <String, Object>{'source': 'tieba', 'id': '10'},
            'author': <String, Object>{'id': '8', 'name': '层主'},
            'body': '回复',
            'floor': 2,
            'replyCount': 1,
            'replies': <Object>[
              <String, Object>{
                'ref': <String, Object>{'source': 'tieba', 'id': '11'},
                'author': <String, Object>{'id': '7', 'name': '回复者'},
                'body': '楼中楼',
              },
            ],
          },
        ],
      }),
    );

    expect(detail.hasMore, isTrue);
    expect(detail.nextCursor, '2');
    expect(detail.comments.single.floor, 2);
    expect(detail.comments.single.replies.single.body, '楼中楼');
  });

  test('floor reply page decodes pagination', () {
    final page = FeedCommentPage.decode(
      jsonEncode(<String, Object?>{
        'comments': <Object?>[
          <String, Object?>{
            'ref': <String, Object?>{
              'source': 'tieba',
              'id': '300',
              'parentId': '200',
              'token': '99',
            },
            'author': <String, Object?>{'id': '84', 'name': '回复者'},
            'body': '完整楼中楼',
            'floor': 2,
          },
        ],
        'nextCursor': '2',
        'hasMore': true,
      }),
    );
    expect(page.comments.single.body, '完整楼中楼');
    expect(page.comments.single.ref.parentId, '200');
    expect(page.comments.single.ref.token, '99');
    expect(page.nextCursor, '2');
    expect(page.hasMore, isTrue);
  });

  test('XHS floor replies retain their source', () {
    final page = FeedCommentPage.decode(
      jsonEncode(<String, Object?>{
        'comments': <Object?>[
          <String, Object?>{
            'ref': <String, Object?>{
              'source': 'xhs',
              'id': 'reply-1',
              'parentId': 'comment-1',
            },
            'author': <String, Object?>{'id': 'user-1', 'name': '回复者'},
            'body': '小红书楼中楼',
          },
        ],
      }),
      source: SourceId.xhs,
    );

    expect(page.comments.single.ref.source, SourceId.xhs);
    expect(page.comments.single.ref.parentId, 'comment-1');
  });

  test('decodes XHS profile metadata and notes', () {
    final page = ProfilePage.decode(
      jsonEncode(<String, Object?>{
        'ref': <String, Object?>{'source': 'xhs', 'id': 'user-1'},
        'name': '创作者',
        'description': '简介',
        'redId': 'red-1',
        'location': '上海',
        'stats': <Object?>[
          <String, Object?>{'name': '粉丝', 'count': '12'},
        ],
        'items': <Object?>[
          <String, Object?>{
            'ref': <String, Object?>{'source': 'xhs', 'id': 'note-1'},
            'title': '笔记',
            'author': <String, Object?>{'id': 'user-1', 'name': '创作者'},
            'stats': <String, Object?>{},
          },
        ],
        'nextCursor': 'more',
        'hasMore': true,
      }),
    );

    expect(page.ref.source, SourceId.xhs);
    expect(page.name, '创作者');
    expect(page.stats.single.name, '粉丝');
    expect(page.items.single.ref.id, 'note-1');
    expect(page.hasMore, isTrue);
  });

  test('XHS scripts cover desktop login, nested replies, and profiles', () {
    expect(xhsDesktopPageScript, contains('width=1280'));
    expect(xhsOpenLoginScript, contains('.login-container .qrcode-img'));
    expect(xhsLoadMoreCommentsScript, contains('.note-scroller'));
    expect(xhsDetailScript('note-1', 'token'), contains('subComments'));
    expect(xhsDetailScript('note-1', 'token'), contains('backupUrls'));
    expect(
      xhsFloorRepliesScript('note-1', 'comment-1'),
      allOf(contains('note-1'), contains('comment-1')),
    );
    expect(
      xhsProfileScript('user-1', 'token'),
      allOf(contains('userPageData'), contains('activeTab')),
    );
  });

  test('XHS search filters keep a stable request key', () {
    const defaults = XhsSearchFilters();
    final filtered = defaults.copyWith(sortBy: '最新', noteType: '图文');

    expect(defaults.isDefault, isTrue);
    expect(filtered.isDefault, isFalse);
    expect(filtered.selections['排序依据'], '最新');
    expect(filtered.selections['笔记类型'], '图文');
    expect(filtered.key, isNot(defaults.key));
  });
}
