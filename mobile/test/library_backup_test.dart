import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/library_backup.dart';
import 'package:mixsocial_mobile/src/library_organizer.dart';
import 'package:mixsocial_mobile/src/models.dart';

const item = FeedItem(
  ref: ContentRef(source: SourceId.xhs, id: '1234567890abcdef12345678', token: 'secret-token', url: 'https://www.xiaohongshu.com/explore/1234567890abcdef12345678?xsec_token=secret-query'),
  title: '标题', summary: '公开摘要',
  author: Author(ref: ProfileRef(source: SourceId.xhs, id: 'user', token: 'secret-profile'), id: 'user', name: '作者', avatar: 'https://example.com/avatar?secret-avatar', following: true),
  stats: ItemStats(), liked: true, favorited: true,
);

Map<String, dynamic> document() => jsonDecode(LibraryBackup.encode(saved: [item], readLater: [item], organization: LibraryOrganization(collections: {'旅行': [item.key]}, items: {item.key: item}, tags: {item.key: ['攻略']}))) as Map<String, dynamic>;

void main() {
  test('public allowlist round trips without account state or signed URLs', () {
    final text = jsonEncode(document());
    for (final secret in ['secret-', 'xsec_token', 'avatar', 'following', 'liked', 'favorited', 'BDUSS', 'cookie']) { expect(text, isNot(contains(secret))); }
    final backup = LibraryBackup.decode(text);
    expect(backup.savedCount, 1); expect(backup.readLaterCount, 1);
    final restored = backup.entries.single;
    expect(restored.item.ref.token, isEmpty);
    expect(restored.item.ref.url, 'https://www.xiaohongshu.com/explore/1234567890abcdef12345678');
    expect(restored.item.liked, isFalse); expect(restored.item.favorited, isFalse);
    expect(restored.collections, ['旅行']); expect(restored.tags, ['攻略']);
  });

  test('duplicate entries merge flags membership and tags', () {
    final json = document();
    final first = (json['items'] as List).single as Map;
    final second = Map<String, dynamic>.from(first)..['saved'] = false..['tags'] = ['相机'];
    (json['items'] as List).add(second);
    final backup = LibraryBackup.decode(jsonEncode(json));
    expect(backup.entries, hasLength(1));
    expect(backup.entries.single.tags, ['攻略', '相机']);
    expect(backup.entries.single.saved, isTrue);
  });

  test('Zhihu public content kind survives backup without credentials', () {
    const answer = FeedItem(
      ref: ContentRef(
        source: SourceId.zhihu,
        id: '456',
        parentId: '123',
        token: 'answer',
        url: 'https://www.zhihu.com/question/123/answer/456?utm_source=app',
      ),
      title: '知乎回答',
      author: Author(
        ref: ProfileRef(source: SourceId.zhihu, id: 'author'),
        id: 'author',
        name: '作者',
      ),
      stats: ItemStats(),
    );
    final backup = LibraryBackup.decode(
      LibraryBackup.encode(
        saved: const <FeedItem>[answer],
        readLater: const <FeedItem>[],
        organization: LibraryOrganization(),
      ),
    );
    final restored = backup.entries.single.item.ref;
    expect(restored.source, SourceId.zhihu);
    expect(restored.token, 'answer');
    expect(restored.parentId, '123');
    expect(restored.url, 'https://www.zhihu.com/question/123/answer/456');
  });

  test('Tieba backup remains compatible after adding Zhihu fields', () {
    const thread = FeedItem(
      ref: ContentRef(source: SourceId.tieba, id: '123'),
      title: '本地帖子',
      author: Author(
        ref: ProfileRef(source: SourceId.tieba, id: 'u'),
        id: 'u',
        name: '作者',
      ),
      stats: ItemStats(),
    );
    final backup = LibraryBackup.decode(
      LibraryBackup.encode(
        saved: const <FeedItem>[thread],
        readLater: const <FeedItem>[thread],
        organization: LibraryOrganization(),
      ),
    );
    expect(backup.entries.single.item.ref.source, SourceId.tieba);
    expect(backup.savedCount, 1);
    expect(backup.readLaterCount, 1);
  });

  test('rejects wrong versions unknown credentials malicious IDs and malformed flags', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (json) => json['version'] = 99,
      (json) => json['cookies'] = 'secret',
      (json) => (json['items'] as List).first['token'] = 'secret',
      (json) => (json['items'] as List).first['id'] = '../../credentials',
      (json) => (json['items'] as List).first['source'] = 'other',
      (json) => (json['items'] as List).first['saved'] = 'true',
      (json) => (json['items'] as List).first['collections'] = ['missing'],
    ]) { final json = document(); mutate(json); expect(() => LibraryBackup.decode(jsonEncode(json)), throwsFormatException); }
  });

  test('rejects byte oversize and invalid JSON before importing anything', () {
    expect(() => LibraryBackup.decode('中' * (LibraryBackup.maxBytes ~/ 3 + 1)), throwsFormatException);
    expect(() => LibraryBackup.decode('{'), throwsFormatException);
    expect(() => LibraryBackup.decode('[]'), throwsFormatException);
  });
}
