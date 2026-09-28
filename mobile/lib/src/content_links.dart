import 'dart:async';

import 'package:flutter/services.dart';

import 'media_tools.dart';
import 'models.dart';

const _linkHosts = {
  'tieba.baidu.com',
  'www.xiaohongshu.com',
  'xiaohongshu.com',
  'xhslink.com',
  'www.zhihu.com',
  'zhihu.com',
  'zhuanlan.zhihu.com',
};

/// Extracts only supported http(s) URLs; unknown text never becomes a WebView URL.
List<Uri> extractContentLinks(String text) {
  if (text.length > 64 * 1024) return const [];
  final values = <String>{};
  return RegExp(r'''https?://[^\s<>"'，。！？、（）【】]+''', caseSensitive: false)
      .allMatches(text)
      .map((match) => match.group(0)!.replaceAll(RegExp(r'[)\].,;!]+$'), ''))
      .map(Uri.tryParse)
      .whereType<Uri>()
      .where(_isSupportedUri)
      .where((uri) => values.add(uri.toString()))
      .take(8)
      .toList();
}

bool _isSupportedUri(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.userInfo.isEmpty &&
    uri.port == (uri.scheme == 'https' ? 443 : 80) &&
    _linkHosts.contains(uri.host) &&
    uri.toString().length <= 8192 &&
    !uri.toString().contains('\\');

ContentRef? contentRefFromUri(Uri uri) {
  if (!_isSupportedUri(uri)) return null;
  if (uri.host == 'tieba.baidu.com') {
    final match = RegExp(r'^/p/([1-9][0-9]{0,19})/?$').firstMatch(uri.path);
    if (match == null) return null;
    final id = match.group(1)!;
    return ContentRef(
      source: SourceId.tieba,
      id: id,
      url: Uri.https('tieba.baidu.com', '/p/$id').toString(),
    );
  }
  if (uri.host == 'www.xiaohongshu.com' || uri.host == 'xiaohongshu.com') {
    final match = RegExp(
      r'^/(?:explore|discovery/item)/([a-fA-F0-9]{24})/?$',
    ).firstMatch(uri.path);
    if (match == null) return null;
    final id = match.group(1)!;
    final token = uri.queryParameters['xsec_token'] ?? '';
    if (token.length > 2048 || token.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return null;
    }
    return ContentRef(
      source: SourceId.xhs,
      id: id,
      url: Uri.https('www.xiaohongshu.com', '/explore/$id', {
        if (token.isNotEmpty) 'xsec_token': token,
        if (token.isNotEmpty) 'xsec_source': 'pc_share',
      }).toString(),
      token: token,
    );
  }
  return _zhihuRef(uri);
}

ContentRef? _zhihuRef(Uri uri) {
  if (uri.host == 'zhuanlan.zhihu.com') {
    final match = RegExp(r'^/p/([1-9][0-9]{0,30})/?$').firstMatch(uri.path);
    if (match == null) return null;
    final id = match.group(1)!;
    return ContentRef(
      source: SourceId.zhihu,
      id: id,
      token: 'article',
      url: Uri.https('zhuanlan.zhihu.com', '/p/$id').toString(),
    );
  }
  if (uri.host != 'www.zhihu.com' && uri.host != 'zhihu.com') return null;
  final answer = RegExp(
    r'^/question/([1-9][0-9]{0,30})/answer/([1-9][0-9]{0,30})/?$',
  ).firstMatch(uri.path);
  if (answer != null) {
    final questionId = answer.group(1)!;
    final answerId = answer.group(2)!;
    return ContentRef(
      source: SourceId.zhihu,
      id: answerId,
      parentId: questionId,
      token: 'answer',
      url: Uri.https(
        'www.zhihu.com',
        '/question/$questionId/answer/$answerId',
      ).toString(),
    );
  }
  for (final kind in const <String>['question', 'pin', 'answer']) {
    final match = RegExp(
      '^/$kind/' r'([1-9][0-9]{0,30})/?$',
    ).firstMatch(uri.path);
    if (match == null) continue;
    final id = match.group(1)!;
    return ContentRef(
      source: SourceId.zhihu,
      id: id,
      token: kind,
      url: Uri.https('www.zhihu.com', '/$kind/$id').toString(),
    );
  }
  return null;
}

Future<ContentRef> resolveContentLink(Uri uri) async {
  final direct = contentRefFromUri(uri);
  if (direct != null) return direct;
  if (!_isSupportedUri(uri) || uri.host != 'xhslink.com') {
    throw const FormatException('请使用贴吧帖子、小红书笔记或知乎内容链接');
  }
  final resolved = await MediaTools.channel.invokeMethod<String>(
    'resolveLink',
    {'url': uri.replace(scheme: 'https').toString()},
  );
  final ref = contentRefFromUri(Uri.tryParse(resolved ?? '') ?? Uri());
  if (ref == null) throw const FormatException('短链接未能解析，请复制完整笔记链接');
  return ref;
}

class IncomingContentLink {
  const IncomingContentLink(this.id, this.text);
  final String id;
  final String text;
}

/// Registers before requesting the cold-start event so no hot-start event is lost.
/// IDs are native per-intent, allowing deliberate sharing of the same URL later.
class IncomingLinkReceiver {
  IncomingLinkReceiver({MethodChannel? channel})
    : _channel = channel ?? MediaTools.channel;

  final MethodChannel _channel;
  final _seen = <String>{};
  final _events = StreamController<IncomingContentLink>.broadcast();
  bool _disposed = false;
  Stream<IncomingContentLink> get events => _events.stream;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'incomingLink') _accept(call.arguments);
    });
    try {
      _accept(await _channel.invokeMethod<Object?>('initialLink'));
    } on MissingPluginException {
      // Desktop/tests have no Android intent provider.
    } on PlatformException {
      // A failed intent never blocks application startup.
    }
  }

  void _accept(Object? value) {
    if (_disposed || value is! Map) return;
    final id = value['id'];
    final text = value['text'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        text is! String ||
        text.length > 64 * 1024 ||
        !_seen.add(id)) {
      return;
    }
    if (_seen.length > 64) _seen.remove(_seen.first);
    _events.add(IncomingContentLink(id, text));
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }
}
