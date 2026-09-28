import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/detail_content_tools.dart';
import 'package:mixsocial_mobile/src/models.dart';

const _item = FeedItem(
  ref: ContentRef(source: SourceId.tieba, id: '12345678'),
  title: '标题',
  summary: '摘要',
  author: Author(
    ref: ProfileRef(source: SourceId.tieba, id: 'author'),
    id: 'author',
    name: '作者',
  ),
  stats: ItemStats(),
);

void main() {
  test('sharing preserves an existing signed web link', () {
    const url = 'https://www.xiaohongshu.com/explore/note?xsec_token=a%2Bb';
    expect(
      contentLink(const ContentRef(source: SourceId.xhs, id: 'note', url: url)),
      url,
    );
  });

  test('sharing builds valid platform links and encodes the note token', () {
    expect(contentLink(_item.ref), 'https://tieba.baidu.com/p/12345678');
    final link = Uri.parse(
      contentLink(
        const ContentRef(
          source: SourceId.xhs,
          id: '66c900000000000000000123',
          token: 'token+value&more',
        ),
      )!,
    );
    expect(link.host, 'www.xiaohongshu.com');
    expect(link.path, '/explore/66c900000000000000000123');
    expect(link.queryParameters['xsec_token'], 'token+value&more');
    expect(
      contentLink(
        const ContentRef(
          source: SourceId.zhihu,
          id: '456',
          parentId: '123',
          token: 'answer',
        ),
      ),
      'https://www.zhihu.com/question/123/answer/456',
    );
    expect(
      contentLink(
        const ContentRef(
          source: SourceId.zhihu,
          id: '321',
          token: 'article',
        ),
      ),
      'https://zhuanlan.zhihu.com/p/321',
    );
  });

  test('sharing rejects unsafe schemes, incomplete URLs and invalid IDs', () {
    for (final url in <String>[
      'javascript:alert(1)',
      'file:///etc/passwd',
      'https:relative',
      '//tieba.baidu.com/p/123',
      'https://user:password@example.com/post',
      '',
    ]) {
      expect(
        contentLink(
          ContentRef(source: SourceId.xhs, id: '../invalid', url: url),
        ),
        isNull,
      );
    }
    expect(
      contentLink(const ContentRef(source: SourceId.tieba, id: '0')),
      isNull,
    );
    expect(
      contentLink(const ContentRef(source: SourceId.all, id: '123')),
      isNull,
    );
  });

  test('copying includes the loaded body and avoids a duplicate title', () {
    expect(contentText(_item, body: '  完整正文\n下一行  '), '标题\n\n完整正文\n下一行');
    expect(contentText(_item), '标题\n\n摘要');
    expect(contentText(_item, body: ' 标题 '), '标题');
    expect(contentText(_item.copyWith(title: ''), body: '正文'), '正文');
  });
}
