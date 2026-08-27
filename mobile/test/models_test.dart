import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/xhs_scripts.dart';

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
  });

  test('profile keys remain source scoped', () {
    const xhs = ProfileRef(source: SourceId.xhs, id: 'same');
    const tieba = ProfileRef(source: SourceId.tieba, id: 'same');

    expect(xhs.key, 'xhs:same');
    expect(tieba.key, 'tieba:same');
    expect(xhs.key, isNot(tieba.key));
  });
}
