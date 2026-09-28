import 'models.dart';

String? contentLink(ContentRef ref) {
  final supplied = Uri.tryParse(ref.url.trim());
  if (supplied != null &&
      (supplied.scheme == 'https' || supplied.scheme == 'http') &&
      supplied.host.isNotEmpty &&
      supplied.userInfo.isEmpty) {
    return supplied.toString();
  }
  final id = ref.id.trim();
  switch (ref.source) {
    case SourceId.xhs:
      if (!RegExp(r'^[a-fA-F0-9]{24}$').hasMatch(id)) return null;
      return Uri.https(
        'www.xiaohongshu.com',
        '/explore/$id',
        ref.token.isEmpty
            ? null
            : <String, String>{
                'xsec_token': ref.token,
                'xsec_source': 'pc_feed',
              },
      ).toString();
    case SourceId.tieba:
      if (!RegExp(r'^[1-9][0-9]*$').hasMatch(id)) return null;
      return Uri.https('tieba.baidu.com', '/p/$id').toString();
    case SourceId.zhihu:
      if (!RegExp(r'^[1-9][0-9]*$').hasMatch(id)) return null;
      return switch (ref.token) {
        'question' => Uri.https('www.zhihu.com', '/question/$id').toString(),
        'article' => Uri.https('zhuanlan.zhihu.com', '/p/$id').toString(),
        'pin' => Uri.https('www.zhihu.com', '/pin/$id').toString(),
        _ => Uri.https(
          'www.zhihu.com',
          ref.parentId.isEmpty
              ? '/answer/$id'
              : '/question/${ref.parentId}/answer/$id',
        ).toString(),
      };
    case SourceId.all:
      return null;
  }
}

String contentText(FeedItem item, {String? body}) {
  final title = item.title.trim();
  final text = (body ?? item.summary).trim();
  if (title.isEmpty) return text;
  if (text.isEmpty || text == title) return title;
  return '$title\n\n$text';
}
