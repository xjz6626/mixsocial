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

  static Future<String> tiebaDetail(String refJson) async {
    return (await _invoke<String>('tieba.detail', <String, Object>{
          'ref': refJson,
        })) ??
        '{}';
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
