import 'models.dart';

String normalizeForumName(String value) {
  var result = value.trim();
  if (result.endsWith('吧')) result = result.substring(0, result.length - 1);
  return result.toLowerCase();
}

String normalizeKeyword(String value) => value.trim().toLowerCase();

class ContentFilters {
  const ContentFilters({
    this.blockedProfiles = const <String>{},
    this.blockedForums = const <String>{},
    this.blockedKeywords = const <String>{},
    this.hideVideos = false,
    this.hideMedia = false,
  });

  final Set<String> blockedForums;
  final Set<String> blockedProfiles;
  final Set<String> blockedKeywords;
  final bool hideVideos;
  final bool hideMedia;

  bool blocks(FeedItem item) {
    if (blocksAuthor(item.author)) return true;
    if (item.ref.source == SourceId.tieba &&
        blockedForums.contains(normalizeForumName(item.forumName))) {
      return true;
    }
    if (hideVideos &&
        item.media.any((MediaItem media) => media.kind == 'video')) {
      return true;
    }
    return blocksText('${item.title}\n${item.summary}');
  }

  bool blocksAuthor(Author author) =>
      author.ref.isIdentifiable && blockedProfiles.contains(author.ref.key);

  bool blocksText(String value) {
    if (blockedKeywords.isEmpty) return false;
    final content = value.toLowerCase();
    return blockedKeywords.any(
      (String keyword) => keyword.isNotEmpty && content.contains(keyword),
    );
  }

  List<FeedItem> apply(Iterable<FeedItem> values) => values
      .where((FeedItem item) => !blocks(item))
      .map(
        (FeedItem item) => hideMedia && item.media.isNotEmpty
            ? item.copyWith(media: const <MediaItem>[])
            : item,
      )
      .toList();

  ContentFilters copyWith({
    Set<String>? blockedProfiles,
    Set<String>? blockedForums,
    Set<String>? blockedKeywords,
    bool? hideVideos,
    bool? hideMedia,
  }) => ContentFilters(
    blockedProfiles: blockedProfiles ?? this.blockedProfiles,
    blockedForums: blockedForums ?? this.blockedForums,
    blockedKeywords: blockedKeywords ?? this.blockedKeywords,
    hideVideos: hideVideos ?? this.hideVideos,
    hideMedia: hideMedia ?? this.hideMedia,
  );
}
