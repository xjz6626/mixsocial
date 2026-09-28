import 'dart:convert';

import 'library_organizer.dart';
import 'models.dart';

class LibraryBackupEntry {
  const LibraryBackupEntry({
    required this.item,
    required this.saved,
    required this.readLater,
    required this.collections,
    required this.tags,
  });
  final FeedItem item;
  final bool saved;
  final bool readLater;
  final List<String> collections;
  final List<String> tags;
}

class LibraryBackup {
  const LibraryBackup(this.entries, this.collections);
  static const format = 'mixsocial-library';
  static const maxBytes = 4 * 1024 * 1024;
  final List<LibraryBackupEntry> entries;
  final List<String> collections;
  int get savedCount => entries.where((entry) => entry.saved).length;
  int get readLaterCount => entries.where((entry) => entry.readLater).length;

  /// Deliberately does not serialize FeedItem.toJson: refs, avatars and media can
  /// contain access tokens or signed/private URLs. This explicit public allowlist
  /// also excludes cookies, account state, platform likes and platform favorites.
  static String encode({
    required List<FeedItem> saved,
    required List<FeedItem> readLater,
    required LibraryOrganization organization,
  }) {
    final items = {
      ...organization.items,
      for (final item in readLater) item.key: item,
      for (final item in saved) item.key: item,
    };
    final savedKeys = saved.map((item) => item.key).toSet();
    final laterKeys = readLater.map((item) => item.key).toSet();
    final result = const JsonEncoder.withIndent('  ').convert({
      'format': format,
      'version': 1,
      'collections': organization.collections.keys.toList(),
      'items': [
        for (final item in items.values)
          {
            'source': item.ref.source.id,
            'id': item.ref.id,
            if (item.ref.source == SourceId.zhihu &&
                const {'answer', 'question', 'article', 'pin'}.contains(
                  item.ref.token,
                ))
              'kind': item.ref.token,
            if (item.ref.source == SourceId.zhihu &&
                item.ref.parentId.isNotEmpty)
              'parentId': item.ref.parentId,
            'title': item.title,
            'summary': item.summary,
            'authorName': item.author.name,
            if (item.forumName.isNotEmpty) 'forum': item.forumName,
            if (item.publishedAt != null)
              'publishedAt': item.publishedAt!.toUtc().toIso8601String(),
            'saved': savedKeys.contains(item.key),
            'readLater': laterKeys.contains(item.key),
            'collections': [
              for (final entry in organization.collections.entries)
                if (entry.value.contains(item.key)) entry.key,
            ],
            'tags': organization.tags[item.key] ?? <String>[],
          },
      ],
    });
    if (utf8.encode(result).length > maxBytes) {
      throw const FormatException('备份超过 4 MiB，请减少内容后重试');
    }
    // Ensure exported documents meet precisely the same validation as imports.
    decode(result);
    return result;
  }

  static LibraryBackup decode(String text) {
    if (text.length > maxBytes || utf8.encode(text).length > maxBytes) {
      throw const FormatException('备份超过 4 MiB');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const FormatException('不是有效的 JSON 备份');
    }
    final json = _object(decoded);
    _keys(json, {'format', 'version', 'collections', 'items'});
    if (json['format'] != format || json['version'] != 1) {
      throw const FormatException('不支持的备份格式或版本');
    }
    final collections = _strings(json['collections'], 100, 60);
    if (collections.map((value) => value.toLowerCase()).toSet().length !=
        collections.length) {
      throw const FormatException('收藏夹名称重复');
    }
    final raw = json['items'];
    if (raw is! List || raw.length > 1200) {
      throw const FormatException('备份最多包含 1200 条内容');
    }
    final entries = <String, LibraryBackupEntry>{};
    for (final value in raw) {
      final row = _object(value);
      _keys(row, {
        'source',
        'id',
        'kind',
        'parentId',
        'title',
        'summary',
        'authorName',
        'forum',
        'publishedAt',
        'saved',
        'readLater',
        'collections',
        'tags',
      });
      final source = SourceId.parse(row['source']);
      final id = _string(row['id'], 100);
      final validId = switch (source) {
        SourceId.tieba => RegExp(r'^\d{1,30}$').hasMatch(id),
        SourceId.xhs => RegExp(r'^[a-fA-F0-9]{24}$').hasMatch(id),
        SourceId.zhihu => RegExp(r'^[1-9][0-9]{0,30}$').hasMatch(id),
        SourceId.all => false,
      };
      if (!validId) {
        throw const FormatException('备份包含无效的平台或帖子 ID');
      }
      final kind = source == SourceId.zhihu
          ? row.containsKey('kind')
                ? _string(row['kind'], 16)
                : 'answer'
          : '';
      if (source == SourceId.zhihu &&
          !const {'answer', 'question', 'article', 'pin'}.contains(kind)) {
        throw const FormatException('备份包含无效的知乎内容类型');
      }
      final parentId = row.containsKey('parentId')
          ? _string(row['parentId'], 40)
          : '';
      if (parentId.isNotEmpty &&
          (source != SourceId.zhihu ||
              kind != 'answer' ||
              !RegExp(r'^[1-9][0-9]{0,30}$').hasMatch(parentId))) {
        throw const FormatException('备份包含无效的知乎问题编号');
      }
      if (row['saved'] is! bool || row['readLater'] is! bool) {
        throw const FormatException('收藏/稍后阅读标记无效');
      }
      final selected = _strings(row['collections'], 100, 60);
      if (selected.any((name) => !collections.contains(name))) {
        throw const FormatException('备份引用了不存在的收藏夹');
      }
      final tags = _strings(row['tags'], 20, 40);
      final forum = row.containsKey('forum') ? _string(row['forum'], 80) : '';
      final published = row.containsKey('publishedAt')
          ? DateTime.tryParse(_string(row['publishedAt'], 40))
          : null;
      if (row.containsKey('publishedAt') && published == null) {
        throw const FormatException('发布时间无效');
      }
      final item = FeedItem(
        ref: ContentRef(
          source: source,
          id: id,
          parentId: parentId,
          token: kind,
          url: switch (source) {
            SourceId.tieba => 'https://tieba.baidu.com/p/$id',
            SourceId.xhs => 'https://www.xiaohongshu.com/explore/$id',
            SourceId.zhihu => switch (kind) {
              'question' => 'https://www.zhihu.com/question/$id',
              'article' => 'https://zhuanlan.zhihu.com/p/$id',
              'pin' => 'https://www.zhihu.com/pin/$id',
              _ when parentId.isNotEmpty =>
                'https://www.zhihu.com/question/$parentId/answer/$id',
              _ => 'https://www.zhihu.com/answer/$id',
            },
            SourceId.all => '',
          },
        ),
        title: _string(row['title'], 1000),
        summary: _string(row['summary'], 20000),
        author: Author(
          ref: ProfileRef(source: source, id: ''),
          id: '',
          name: _string(row['authorName'], 120),
        ),
        stats: const ItemStats(),
        publishedAt: published,
        tags: source == SourceId.tieba && forum.isNotEmpty ? [forum] : const [],
      );
      final previous = entries[item.key];
      final mergedTags = LibraryOrganizerStore.normalizeTags([
        ...?previous?.tags,
        ...tags,
      ]);
      entries[item.key] = LibraryBackupEntry(
        item: previous?.item ?? item,
        saved: row['saved'] == true || previous?.saved == true,
        readLater: row['readLater'] == true || previous?.readLater == true,
        collections: {...?previous?.collections, ...selected}.toList(),
        tags: mergedTags,
      );
    }
    final result = LibraryBackup(entries.values.toList(), collections);
    if (result.savedCount > 300 || result.readLaterCount > 300) {
      throw const FormatException('收藏与稍后阅读各最多 300 条');
    }
    return result;
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, dynamic>) throw const FormatException('备份对象结构无效');
    return value.cast<String, Object?>();
  }

  static void _keys(Map<String, Object?> json, Set<String> allowed) {
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('备份含未知字段，可能包含凭据；请使用 App 导出的备份');
    }
  }

  static String _string(Object? value, int max) {
    if (value is! String || value.length > max) {
      throw const FormatException('备份文本字段无效或过长');
    }
    return value;
  }

  static List<String> _strings(Object? value, int maxCount, int maxLength) {
    if (value is! List || value.length > maxCount) {
      throw const FormatException('备份列表无效或过长');
    }
    final result = value
        .map((item) => _string(item, maxLength).trim())
        .toList();
    if (result.any((item) => item.isEmpty)) {
      throw const FormatException('名称或标签不能为空');
    }
    return result.toSet().toList();
  }
}
