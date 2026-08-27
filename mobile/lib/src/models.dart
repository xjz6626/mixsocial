import 'dart:convert';

enum SourceId {
  all('all', '全部'),
  xhs('xhs', '小红书'),
  tieba('tieba', '贴吧');

  const SourceId(this.id, this.label);
  final String id;
  final String label;

  static SourceId parse(Object? value) => switch (value?.toString()) {
    'xhs' => SourceId.xhs,
    'tieba' => SourceId.tieba,
    _ => SourceId.all,
  };
}

enum FeedChannel {
  recommend('recommend', '推荐'),
  hot('hot', '热榜'),
  following('following', '关注');

  const FeedChannel(this.id, this.label);
  final String id;
  final String label;
}

enum FeedLayout { masonry, list }

enum SourceCapability {
  feed,
  search,
  detail,
  like,
  favorite,
  comment,
  reply,
  hot,
  followingFeed,
  login,
  follow,
  block,
}

class ContentRef {
  const ContentRef({
    required this.source,
    required this.id,
    this.parentId = '',
    this.token = '',
    this.url = '',
  });

  final SourceId source;
  final String id;
  final String parentId;
  final String token;
  final String url;

  factory ContentRef.fromJson(Map<String, Object?> json) => ContentRef(
    source: SourceId.parse(json['source']),
    id: json['id']?.toString() ?? '',
    parentId: json['parentId']?.toString() ?? '',
    token: json['token']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.id,
    'id': id,
    if (parentId.isNotEmpty) 'parentId': parentId,
    if (token.isNotEmpty) 'token': token,
    if (url.isNotEmpty) 'url': url,
  };
}

class ProfileRef {
  const ProfileRef({
    required this.source,
    required this.id,
    this.token = '',
    this.url = '',
  });

  final SourceId source;
  final String id;
  final String token;
  final String url;

  String get key => '${source.id}:$id';

  factory ProfileRef.fromJson(Map<String, Object?> json) => ProfileRef(
    source: SourceId.parse(json['source']),
    id: json['id']?.toString() ?? '',
    token: json['token']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.id,
    'id': id,
    if (token.isNotEmpty) 'token': token,
    if (url.isNotEmpty) 'url': url,
  };
}

class Author {
  const Author({
    required this.ref,
    required this.id,
    required this.name,
    this.avatar = '',
    this.following = false,
    this.blocked = false,
  });

  final ProfileRef ref;
  final String id;
  final String name;
  final String avatar;
  final bool following;
  final bool blocked;

  factory Author.fromJson(Map<String, Object?> json, SourceId source) {
    final refJson = mapOf(json['ref']);
    return Author(
      ref: refJson.isEmpty
          ? ProfileRef(source: source, id: json['id']?.toString() ?? '')
          : ProfileRef.fromJson(refJson),
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未知用户',
      avatar: json['avatar']?.toString() ?? '',
      following: json['following'] == true,
      blocked: json['blocked'] == true,
    );
  }

  Author copyWith({
    ProfileRef? ref,
    String? id,
    String? name,
    String? avatar,
    bool? following,
    bool? blocked,
  }) => Author(
    ref: ref ?? this.ref,
    id: id ?? this.id,
    name: name ?? this.name,
    avatar: avatar ?? this.avatar,
    following: following ?? this.following,
    blocked: blocked ?? this.blocked,
  );
}

class ItemStats {
  const ItemStats({
    this.views = 0,
    this.likes = 0,
    this.comments = 0,
    this.favorites = 0,
    this.shares = 0,
  });

  final int views;
  final int likes;
  final int comments;
  final int favorites;
  final int shares;

  factory ItemStats.fromJson(Map<String, Object?> json) => ItemStats(
    views: integer(json['views']),
    likes: integer(json['likes']),
    comments: integer(json['comments']),
    favorites: integer(json['favorites']),
    shares: integer(json['shares']),
  );

  ItemStats copyWith({
    int? views,
    int? likes,
    int? comments,
    int? favorites,
    int? shares,
  }) => ItemStats(
    views: views ?? this.views,
    likes: likes ?? this.likes,
    comments: comments ?? this.comments,
    favorites: favorites ?? this.favorites,
    shares: shares ?? this.shares,
  );
}

class MediaItem {
  const MediaItem({
    required this.kind,
    this.url = '',
    this.previewUrl = '',
    this.format = '',
    this.width = 0,
    this.height = 0,
    this.durationMilliseconds = 0,
  });

  final String kind;
  final String url;
  final String previewUrl;
  final String format;
  final int width;
  final int height;
  final int durationMilliseconds;

  String get displayUrl => previewUrl.isNotEmpty ? previewUrl : url;
  double get aspectRatio => width > 0 && height > 0 ? width / height : 3 / 4;

  factory MediaItem.fromJson(Map<String, Object?> json) => MediaItem(
    kind: json['kind']?.toString() ?? 'image',
    url: json['url']?.toString() ?? '',
    previewUrl: json['previewUrl']?.toString() ?? '',
    format: json['format']?.toString() ?? '',
    width: integer(json['width']),
    height: integer(json['height']),
    // Go's time.Duration JSON value is nanoseconds. WebView adapters return
    // durationMilliseconds directly.
    durationMilliseconds: json.containsKey('durationMilliseconds')
        ? integer(json['durationMilliseconds'])
        : integer(json['duration']) ~/ 1000000,
  );
}

class FeedItem {
  const FeedItem({
    required this.ref,
    required this.title,
    required this.author,
    required this.stats,
    this.summary = '',
    this.publishedAt,
    this.media = const <MediaItem>[],
    this.tags = const <String>[],
    this.liked = false,
    this.favorited = false,
  });

  final ContentRef ref;
  final String title;
  final String summary;
  final Author author;
  final DateTime? publishedAt;
  final ItemStats stats;
  final List<MediaItem> media;
  final List<String> tags;
  final bool liked;
  final bool favorited;

  factory FeedItem.fromJson(Map<String, Object?> json) {
    final ref = ContentRef.fromJson(mapOf(json['ref']));
    return FeedItem(
      ref: ref,
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      author: Author.fromJson(mapOf(json['author']), ref.source),
      publishedAt: DateTime.tryParse(json['publishedAt']?.toString() ?? ''),
      stats: ItemStats.fromJson(mapOf(json['stats'])),
      media: listOfMaps(json['media']).map(MediaItem.fromJson).toList(),
      tags: listOf(
        json['tags'],
      ).map((Object? value) => value.toString()).toList(),
      liked: json['liked'] == true,
      favorited: json['favorited'] == true,
    );
  }

  FeedItem copyWith({
    String? title,
    String? summary,
    Author? author,
    ItemStats? stats,
    List<MediaItem>? media,
    List<String>? tags,
    bool? liked,
    bool? favorited,
  }) => FeedItem(
    ref: ref,
    title: title ?? this.title,
    summary: summary ?? this.summary,
    author: author ?? this.author,
    publishedAt: publishedAt,
    stats: stats ?? this.stats,
    media: media ?? this.media,
    tags: tags ?? this.tags,
    liked: liked ?? this.liked,
    favorited: favorited ?? this.favorited,
  );
}

class FeedPage {
  const FeedPage({
    this.items = const <FeedItem>[],
    this.nextCursor = '',
    this.hasMore = false,
    this.notices = const <String>[],
  });

  final List<FeedItem> items;
  final String nextCursor;
  final bool hasMore;
  final List<String> notices;

  factory FeedPage.fromJson(Map<String, Object?> json) => FeedPage(
    items: listOfMaps(json['items']).map(FeedItem.fromJson).toList(),
    nextCursor: json['nextCursor']?.toString() ?? '',
    hasMore: json['hasMore'] == true,
    notices: listOf(
      json['notices'],
    ).map((Object? value) => value.toString()).toList(),
  );

  static FeedPage decode(String value) =>
      FeedPage.fromJson(mapOf(jsonDecode(value)));
}

class FeedComment {
  const FeedComment({
    required this.ref,
    required this.author,
    required this.body,
    this.likes = 0,
  });

  final ContentRef ref;
  final Author author;
  final String body;
  final int likes;

  factory FeedComment.fromJson(Map<String, Object?> json, SourceId source) {
    final refJson = mapOf(json['ref']);
    return FeedComment(
      ref: refJson.isEmpty
          ? ContentRef(source: source, id: json['id']?.toString() ?? '')
          : ContentRef.fromJson(refJson),
      author: Author.fromJson(mapOf(json['author']), source),
      body: json['body']?.toString() ?? '',
      likes: integer(json['likes']),
    );
  }
}

class FeedDetail {
  const FeedDetail({
    required this.item,
    required this.body,
    this.comments = const <FeedComment>[],
  });
  final FeedItem item;
  final String body;
  final List<FeedComment> comments;

  factory FeedDetail.fromJson(Map<String, Object?> json) {
    final item = FeedItem.fromJson(json);
    return FeedDetail(
      item: item,
      body: json['body']?.toString() ?? item.summary,
      comments: listOfMaps(json['comments'])
          .map(
            (Map<String, Object?> value) =>
                FeedComment.fromJson(value, item.ref.source),
          )
          .toList(),
    );
  }

  static FeedDetail decode(String value) =>
      FeedDetail.fromJson(mapOf(jsonDecode(value)));
}

Map<String, Object?> mapOf(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map(
      (Object? key, Object? item) => MapEntry(key.toString(), item),
    );
  }
  return <String, Object?>{};
}

List<Object?> listOf(Object? value) =>
    value is List ? value : const <Object?>[];

List<Map<String, Object?>> listOfMaps(Object? value) =>
    listOf(value).map(mapOf).toList();

int integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
