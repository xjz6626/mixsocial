import 'models.dart';

List<FeedItem> filterLibraryItems(
  Iterable<FeedItem> items, {
  String query = '',
  SourceId source = SourceId.all,
}) {
  final terms = query.trim().toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((term) => term.isEmpty);
  return items.where((item) {
    if (source != SourceId.all && item.ref.source != source) return false;
    final text = <String>[
      item.title,
      item.summary,
      item.author.name,
      item.forumName,
      ...item.tags,
    ].join('\n').toLowerCase();
    return terms.every(text.contains);
  }).toList();
}
