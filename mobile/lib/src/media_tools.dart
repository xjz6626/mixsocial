import 'package:flutter/services.dart';

import 'models.dart';
import 'network_media.dart';

/// User-initiated system actions. Never includes the application's login cookies.
class MediaTools {
  static const channel = MethodChannel('mixsocial/media_tools');

  static Future<void> shareText(String text, {String title = '分享'}) async {
    if (text.trim().isEmpty || text.length > 128 * 1024) {
      throw const FormatException('分享文本为空或过长');
    }
    await channel.invokeMethod<void>('shareText', {
      'text': text,
      'title': title,
    });
  }

  static Future<void> shareTextFile(
    String text, {
    required String fileName,
    String mimeType = 'application/json',
  }) async {
    if (text.length > 4 * 1024 * 1024 ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$').hasMatch(fileName) ||
        !const ['application/json', 'text/plain'].contains(mimeType)) {
      throw const FormatException('导出文件过大或格式无效');
    }
    await channel.invokeMethod<void>('shareTextFile', {
      'text': text,
      'fileName': fileName,
      'mimeType': mimeType,
    });
  }

  static Future<void> image(
    MediaItem media,
    SourceId source, {
    required bool save,
  }) async {
    final candidates = mediaImageCandidates(
      media,
      source,
      MediaImageQuality.original,
    ).where((url) => isSupportedDownloadUrl(url, source)).toList();
    if (candidates.isEmpty) {
      throw const FormatException('图片地址不属于受支持的平台，无法保存或分享');
    }
    await channel.invokeMethod<void>(save ? 'saveImage' : 'shareImage', {
      'urls': candidates.take(3).toList(),
      'source': source.id,
    });
  }

  static Future<int> temporaryCacheBytes() async =>
      await channel.invokeMethod<int>('cacheBytes') ?? 0;

  static Future<void> clearTemporaryCache() async =>
      channel.invokeMethod<void>('clearCache');
}

bool isSupportedDownloadUrl(String value, SourceId source) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      value.length > 8192) {
    return false;
  }
  final domains = switch (source) {
    SourceId.xhs => const ['xhscdn.com', 'xiaohongshu.com'],
    SourceId.tieba => const [
      'baidu.com',
      'bdimg.com',
      'bdstatic.com',
      'bcebos.com',
    ],
    SourceId.zhihu => const ['zhimg.com', 'zhihu.com'],
    SourceId.all => const <String>[],
  };
  return domains.any((host) => uri.host == host || uri.host.endsWith('.$host'));
}
