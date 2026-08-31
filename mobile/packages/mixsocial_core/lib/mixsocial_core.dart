import 'dart:async';

import 'package:flutter/services.dart';

class MixsocialCore {
  MixsocialCore._();

  static const MethodChannel _channel = MethodChannel('mixsocial/core');
  static int _nextRequest = 0;
  static Duration _operationTimeout = const Duration(seconds: 47);

  static Future<void> configureTieba({
    List<String> forums = const <String>[],
    String timeout = '45s',
  }) async {
    await _channel.invokeMethod<void>('tieba.configure', <String, Object>{
      'forums': forums,
      'timeout': timeout,
    });
    _operationTimeout = _durationFromGo(timeout) + const Duration(seconds: 2);
  }

  static Future<String> browseTieba(String channel, String cursor) async {
    return (await _invoke<String>('tieba.browse', <String, Object>{
          'channel': channel,
          'cursor': cursor,
        })) ??
        '{"items":[]}';
  }

  static Future<String> searchTieba(String query, String cursor) async {
    return (await _invoke<String>('tieba.search', <String, Object>{
          'query': query,
          'cursor': cursor,
        })) ??
        '{"items":[]}';
  }

  static Future<String> forumTieba(
    String forum,
    String cursor, {
    int sortType = 0,
  }) async {
    return (await _invoke<String>('tieba.forum', <String, Object>{
          'forum': forum,
          'cursor': cursor,
          'sortType': sortType,
        })) ??
        '{"items":[]}';
  }

  static Future<String> searchForumTieba(
    String forum,
    String query,
    String cursor,
  ) async {
    return (await _invoke<String>('tieba.searchForum', <String, Object>{
          'forum': forum,
          'query': query,
          'cursor': cursor,
        })) ??
        '{"items":[]}';
  }

  static Future<String> followingForumsTieba() async {
    return (await _invoke<String>(
          'tieba.followingForums',
          const <String, Object>{},
        )) ??
        '[]';
  }

  static Future<String> tiebaDetail(String refJson) async {
    return (await _invoke<String>('tieba.detail', <String, Object>{
          'ref': refJson,
        })) ??
        '{}';
  }

  static Future<String> tiebaDetailPage(
    String refJson,
    String cursor, {
    bool reverse = false,
    bool onlyOriginalPoster = false,
  }) async {
    return (await _invoke<String>('tieba.detailPage', <String, Object>{
          'ref': refJson,
          'cursor': cursor,
          'reverse': reverse,
          'onlyOriginalPoster': onlyOriginalPoster,
        })) ??
        '{}';
  }

  static Future<String> floorRepliesTieba(String refJson, String cursor) async {
    return (await _invoke<String>('tieba.floorReplies', <String, Object>{
          'ref': refJson,
          'cursor': cursor,
        })) ??
        '{"comments":[]}';
  }

  static Future<String> loginTieba(String credential) async {
    return (await _invoke<String>('tieba.login', <String, Object>{
          'credential': credential,
        })) ??
        '{}';
  }

  static Future<void> clearTiebaCredential() async {
    await _channel.invokeMethod<void>('tieba.clearCredential');
  }

  /// Downloads and normalizes an image with Android's native image stack.
  ///
  /// Some Tieba/XHS CDN responses that Android image loaders accept are not
  /// rendered reliably by Flutter's NetworkImage on every device. The native
  /// bridge decodes the response with BitmapFactory and returns a conventional
  /// JPEG/PNG, so the Flutter side only has to paint known-good bytes.
  static Future<Uint8List> fetchImage(
    String url, {
    Map<String, String> headers = const <String, String>{},
    int maxDimension = 2048,
  }) async {
    final bytes = await _channel
        .invokeMethod<Uint8List>('media.fetchImage', <String, Object>{
          'url': url,
          'headers': headers,
          'maxDimension': maxDimension,
        })
        .timeout(const Duration(seconds: 35));
    if (bytes == null || bytes.isEmpty) {
      throw const MixsocialCoreException('MEDIA_EMPTY', '媒体响应为空');
    }
    return bytes;
  }

  static Future<T?> _invoke<T>(
    String method,
    Map<String, Object> arguments,
  ) async {
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_nextRequest++}';
    final values = <String, Object>{...arguments, 'requestId': requestId};
    try {
      return await _channel
          .invokeMethod<T>(method, values)
          .timeout(_operationTimeout);
    } on TimeoutException {
      unawaited(
        _channel.invokeMethod<void>('tieba.cancel', <String, Object>{
          'requestId': requestId,
        }),
      );
      throw const MixsocialCoreException('TIMEOUT', '贴吧请求超时');
    } on PlatformException catch (error) {
      throw MixsocialCoreException(error.code, error.message ?? '移动核心调用失败');
    }
  }

  static Duration _durationFromGo(String value) {
    final match = RegExp(r'^(\d+)(ms|s|m)$').firstMatch(value.trim());
    if (match == null) return const Duration(seconds: 45);
    final amount = int.parse(match.group(1)!);
    return switch (match.group(2)) {
      'ms' => Duration(milliseconds: amount),
      'm' => Duration(minutes: amount),
      _ => Duration(seconds: amount),
    };
  }
}

class MixsocialCoreException implements Exception {
  const MixsocialCoreException(this.code, this.message);

  final String code;
  final String message;

  bool get cancelled => code == 'CANCELLED';
  bool get timedOut => code == 'TIMEOUT';

  @override
  String toString() => message;
}
