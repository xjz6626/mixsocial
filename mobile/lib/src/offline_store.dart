import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

class OfflineEntry {
  const OfflineEntry({
    required this.detail,
    required this.savedAt,
    this.images = const {},
    this.bytes = 0,
    this.storedImageCount,
  });
  final FeedDetail detail;
  final DateTime savedAt;
  final Map<String, Uint8List> images;
  final int bytes;
  final int? storedImageCount;
  int get imageCount => storedImageCount ?? images.length;
}

/// Explicit downloads live outside the evictable image/feed caches. No cookies,
/// WebView state, or automatically fetched comments are included.
class OfflineStore {
  OfflineStore({this.directory, this.quotaBytes = 200 * 1024 * 1024});
  final Directory? directory;
  final int quotaBytes;
  static Future<void> _writes = Future.value();

  Future<Directory> _root() async {
    final root =
        directory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/offline-reading-v1',
        );
    await root.create(recursive: true);
    return root;
  }

  String _name(String key) => '${base64Url.encode(utf8.encode(key))}.json';

  Future<OfflineEntry?> read(String key) async {
    final file = File('${(await _root()).path}/${_name(key)}');
    if (!await file.exists()) return null;
    return _decode(file, expectedKey: key);
  }

  Future<OfflineEntry> _decode(
    File file, {
    String? expectedKey,
    bool includeImages = true,
  }) async {
    final length = await file.length();
    if (length > quotaBytes) throw const FormatException('离线文件超过容量限制');
    final json = mapOf(jsonDecode(await file.readAsString()));
    final detail = FeedDetail.fromJson(mapOf(json['detail']));
    if (json['version'] != 1 ||
        (expectedKey != null && detail.item.key != expectedKey)) {
      throw const FormatException('离线文件不匹配');
    }
    return OfflineEntry(
      detail: detail,
      savedAt: DateTime.parse(json['savedAt'] as String),
      bytes: length,
      storedImageCount: mapOf(json['images']).length,
      images: {
        if (includeImages)
          for (final entry in mapOf(json['images']).entries)
            entry.key: base64Decode(entry.value as String),
      },
    );
  }

  Future<List<OfflineEntry>> list() async {
    final entries = <OfflineEntry>[];
    await for (final file in (await _root()).list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        entries.add(await _decode(file, includeImages: false));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return entries;
  }

  Future<void> save(FeedDetail detail, Map<String, Uint8List> images) {
    final next = _writes.then((_) async {
      final root = await _root();
      final destination = File('${root.path}/${_name(detail.item.key)}');
      final data = utf8.encode(
        jsonEncode({
          'version': 1,
          'savedAt': DateTime.now().toUtc().toIso8601String(),
          'detail': {
            ...detail.item.toJson(),
            'body': detail.body,
            'contentHtml': detail.contentHtml,
            'answers': detail.answers.map((answer) => answer.toJson()).toList(),
          },
          'images': {
            for (final image in images.entries)
              image.key: base64Encode(image.value),
          },
        }),
      );
      var used = 0;
      await for (final file in root.list()) {
        if (file is File &&
            file.path != destination.path &&
            file.path.endsWith('.json')) {
          used += await file.length();
        }
      }
      if (used + data.length > quotaBytes) {
        throw const FormatException('离线空间已满（200 MiB），请先删除不需要的下载');
      }
      final pending = File('${destination.path}.tmp');
      try {
        await pending.writeAsBytes(data, flush: true);
        await pending.rename(destination.path);
      } finally {
        if (await pending.exists()) await pending.delete();
      }
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> remove(String key) async {
    await _writes;
    final file = File('${(await _root()).path}/${_name(key)}');
    if (await file.exists()) await file.delete();
  }
}
