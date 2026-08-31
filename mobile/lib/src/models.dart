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

enum FeedDensity {
  compact('紧凑'),
  standard('标准'),
  comfortable('舒适');

  const FeedDensity(this.label);
  final String label;
}

enum ProfileSection {
  notes('note', '笔记'),
  favorites('fav', '收藏'),
  liked('liked', '点赞');

  const ProfileSection(this.id, this.label);
  final String id;
  final String label;
}

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
}

final RegExp _internalEmoticonPattern = RegExp(
  r'(?:#\()?image_emoticon(\d*)(?:\))?',
  caseSensitive: false,
);
final RegExp _namedEmoticonPattern = RegExp(r'#\(([^()\n]{1,16})\)');

const Map<String, String> _emoticonGlyphById = <String, String>{
  '1': '🙂',
  '2': '😄',
  '3': '😛',
  '4': '😮',
  '5': '😎',
  '6': '😠',
  '7': '😊',
  '8': '😅',
  '9': '😢',
  '10': '😑',
  '11': '🙄',
  '12': '☹️',
  '13': '👍',
  '14': '🤑',
  '15': '🤔',
  '16': '😏',
  '17': '🤮',
  '18': '🤨',
  '19': '🥺',
  '20': '😍',
  '21': '😮‍💨',
  '22': '😆',
  '23': '🥶',
  '24': '🤣',
  '25': '😏',
  '26': '😬',
  '27': '😰',
  '28': '😇',
  '29': '😴',
  '30': '😱',
  '31': '😡',
  '32': '😲',
  '33': '💦',
  '34': '❤️',
  '35': '💔',
  '36': '🌹',
  '37': '🎁',
  '38': '🌈',
  '39': '🌙⭐',
  '40': '☀️',
  '41': '🪙',
  '42': '💡',
  '43': '☕',
  '44': '🎂',
  '45': '🎵',
  '46': '😂',
  '47': '✌️',
  '48': '👍',
  '49': '👎',
  '50': '👌',
  '61': '😡',
  '77': '🛋️',
  '78': '🧻',
  '79': '🍌',
  '80': '💩',
  '81': '💊',
  '82': '🧣',
  '83': '🕯️',
  '84': '☰',
  '89': '🤭',
};

const Map<String, String> _emoticonGlyphByName = <String, String>{
  '呵呵': '🙂',
  '哈哈': '😄',
  '吐舌': '😛',
  '啊': '😮',
  '酷': '😎',
  '怒': '😠',
  '开心': '😊',
  '汗': '😅',
  '泪': '😢',
  '黑线': '😑',
  '鄙视': '🙄',
  '不高兴': '☹️',
  '真棒': '👍',
  '钱': '🤑',
  '疑问': '🤔',
  '阴险': '😏',
  '吐': '🤮',
  '咦': '🤨',
  '委屈': '🥺',
  '花心': '😍',
  '呼~': '😮‍💨',
  '笑眼': '😆',
  '冷': '🥶',
  '太开心': '🤣',
  '滑稽': '😏',
  '勉强': '😬',
  '狂汗': '😰',
  '乖': '😇',
  '睡觉': '😴',
  '惊哭': '😱',
  '生气': '😡',
  '惊讶': '😲',
  '喷': '💦',
  '爱心': '❤️',
  '心碎': '💔',
  '玫瑰': '🌹',
  '礼物': '🎁',
  '彩虹': '🌈',
  '星星月亮': '🌙⭐',
  '太阳': '☀️',
  '钱币': '🪙',
  '灯泡': '💡',
  '茶杯': '☕',
  '蛋糕': '🎂',
  '音乐': '🎵',
  'haha': '😂',
  '胜利': '✌️',
  '大拇指': '👍',
  '弱': '👎',
  'OK': '👌',
  '沙发': '🛋️',
  '手纸': '🧻',
  '香蕉': '🍌',
  '便便': '💩',
  '药丸': '💊',
  '红领巾': '🧣',
  '蜡烛': '🕯️',
  '三道杠': '☰',
  '噗': '🤭',
};

/// Converts source-internal emoticon asset IDs into a readable inline glyph.
///
/// Known classic/emoji resources use a meaning-preserving Unicode fallback.
/// Unknown IDs render as a neutral label instead of leaking an implementation
/// resource name into user-visible text.
String normalizeSocialText(String value) {
  final resources = value.replaceAllMapped(_internalEmoticonPattern, (
    Match match,
  ) {
    return _emoticonGlyphById[match.group(1)] ?? '[表情]';
  });
  return resources.replaceAllMapped(_namedEmoticonPattern, (Match match) {
    return _emoticonGlyphByName[match.group(1)] ?? match.group(0)!;
  });
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
  });

  final ProfileRef ref;
  final String id;
  final String name;
  final String avatar;
  final bool following;

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
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'ref': ref.toJson(),
    'id': id,
    'name': name,
    if (avatar.isNotEmpty) 'avatar': avatar,
    if (following) 'following': true,
  };

  Author copyWith({
    ProfileRef? ref,
    String? id,
    String? name,
    String? avatar,
    bool? following,
  }) => Author(
    ref: ref ?? this.ref,
    id: id ?? this.id,
    name: name ?? this.name,
    avatar: avatar ?? this.avatar,
    following: following ?? this.following,
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

  Map<String, Object?> toJson() => <String, Object?>{
    if (views != 0) 'views': views,
    if (likes != 0) 'likes': likes,
    if (comments != 0) 'comments': comments,
    if (favorites != 0) 'favorites': favorites,
    if (shares != 0) 'shares': shares,
  };

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

  // A video URL is not an image. Render its cover when present and otherwise
  // show the video placeholder/play button instead of feeding MP4 bytes to an
  // image decoder (which previously resulted in an unexplained grey tile).
  String get displayUrl => kind == 'video'
      ? previewUrl
      : previewUrl.isNotEmpty
      ? previewUrl
      : url;
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

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    if (url.isNotEmpty) 'url': url,
    if (previewUrl.isNotEmpty) 'previewUrl': previewUrl,
    if (format.isNotEmpty) 'format': format,
    if (width != 0) 'width': width,
    if (height != 0) 'height': height,
    if (durationMilliseconds != 0) 'durationMilliseconds': durationMilliseconds,
  };
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

  String get key => '${ref.source.id}:${ref.id}';

  String get forumName {
    if (ref.source != SourceId.tieba || tags.isEmpty) return '';
    final value = tags.first.trim();
    return value.endsWith('吧') ? value.substring(0, value.length - 1) : value;
  }

  factory FeedItem.fromJson(Map<String, Object?> json) {
    final ref = ContentRef.fromJson(mapOf(json['ref']));
    return FeedItem(
      ref: ref,
      title: normalizeSocialText(json['title']?.toString() ?? ''),
      summary: normalizeSocialText(json['summary']?.toString() ?? ''),
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

  Map<String, Object?> toJson() => <String, Object?>{
    'ref': ref.toJson(),
    'title': title,
    if (summary.isNotEmpty) 'summary': summary,
    'author': author.toJson(),
    if (publishedAt != null)
      'publishedAt': publishedAt!.toUtc().toIso8601String(),
    'stats': stats.toJson(),
    if (media.isNotEmpty)
      'media': media.map((MediaItem item) => item.toJson()).toList(),
    if (tags.isNotEmpty) 'tags': tags,
    if (liked) 'liked': true,
    if (favorited) 'favorited': true,
  };

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
    this.publishedAt,
    this.floor = 0,
    this.likes = 0,
    this.replyCount = 0,
    this.media = const <MediaItem>[],
    this.replies = const <FeedComment>[],
  });

  final ContentRef ref;
  final Author author;
  final String body;
  final DateTime? publishedAt;
  final int floor;
  final int likes;
  final int replyCount;
  final List<MediaItem> media;
  final List<FeedComment> replies;

  factory FeedComment.fromJson(Map<String, Object?> json, SourceId source) {
    final refJson = mapOf(json['ref']);
    return FeedComment(
      ref: refJson.isEmpty
          ? ContentRef(source: source, id: json['id']?.toString() ?? '')
          : ContentRef.fromJson(refJson),
      author: Author.fromJson(mapOf(json['author']), source),
      body: normalizeSocialText(json['body']?.toString() ?? ''),
      publishedAt: DateTime.tryParse(json['publishedAt']?.toString() ?? ''),
      floor: integer(json['floor']),
      likes: integer(json['likes']),
      replyCount: integer(json['replyCount']),
      media: listOfMaps(json['media']).map(MediaItem.fromJson).toList(),
      replies: listOfMaps(json['replies'])
          .map(
            (Map<String, Object?> value) => FeedComment.fromJson(value, source),
          )
          .toList(),
    );
  }

  FeedComment copyWith({List<MediaItem>? media, List<FeedComment>? replies}) =>
      FeedComment(
        ref: ref,
        author: author,
        body: body,
        publishedAt: publishedAt,
        floor: floor,
        likes: likes,
        replyCount: replyCount,
        media: media ?? this.media,
        replies: replies ?? this.replies,
      );
}

class FeedCommentPage {
  const FeedCommentPage({
    this.comments = const <FeedComment>[],
    this.nextCursor = '',
    this.hasMore = false,
  });

  final List<FeedComment> comments;
  final String nextCursor;
  final bool hasMore;

  factory FeedCommentPage.fromJson(
    Map<String, Object?> json, {
    SourceId source = SourceId.tieba,
  }) => FeedCommentPage(
    comments: listOfMaps(json['comments'])
        .map(
          (Map<String, Object?> value) => FeedComment.fromJson(value, source),
        )
        .toList(),
    nextCursor: json['nextCursor']?.toString() ?? '',
    hasMore: json['hasMore'] == true,
  );

  static FeedCommentPage decode(
    String value, {
    SourceId source = SourceId.tieba,
  }) => FeedCommentPage.fromJson(mapOf(jsonDecode(value)), source: source);
}

class ProfileStat {
  const ProfileStat({required this.name, required this.count});

  final String name;
  final String count;

  factory ProfileStat.fromJson(Map<String, Object?> json) => ProfileStat(
    name: json['name']?.toString() ?? '',
    count: json['count']?.toString() ?? '0',
  );
}

class ProfilePage {
  const ProfilePage({
    required this.ref,
    required this.name,
    this.avatar = '',
    this.description = '',
    this.redId = '',
    this.location = '',
    this.stats = const <ProfileStat>[],
    this.items = const <FeedItem>[],
    this.nextCursor = '',
    this.hasMore = false,
  });

  final ProfileRef ref;
  final String name;
  final String avatar;
  final String description;
  final String redId;
  final String location;
  final List<ProfileStat> stats;
  final List<FeedItem> items;
  final String nextCursor;
  final bool hasMore;

  factory ProfilePage.fromJson(Map<String, Object?> json) => ProfilePage(
    ref: ProfileRef.fromJson(mapOf(json['ref'])),
    name: json['name']?.toString() ?? '未知用户',
    avatar: json['avatar']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    redId: json['redId']?.toString() ?? '',
    location: json['location']?.toString() ?? '',
    stats: listOfMaps(json['stats']).map(ProfileStat.fromJson).toList(),
    items: listOfMaps(json['items']).map(FeedItem.fromJson).toList(),
    nextCursor: json['nextCursor']?.toString() ?? '',
    hasMore: json['hasMore'] == true,
  );

  static ProfilePage decode(String value) =>
      ProfilePage.fromJson(mapOf(jsonDecode(value)));
}

class FeedDetail {
  const FeedDetail({
    required this.item,
    required this.body,
    this.comments = const <FeedComment>[],
    this.nextCursor = '',
    this.hasMore = false,
  });
  final FeedItem item;
  final String body;
  final List<FeedComment> comments;
  final String nextCursor;
  final bool hasMore;

  factory FeedDetail.fromJson(Map<String, Object?> json) {
    final item = FeedItem.fromJson(json);
    return FeedDetail(
      item: item,
      body: normalizeSocialText(json['body']?.toString() ?? item.summary),
      comments: listOfMaps(json['comments'])
          .map(
            (Map<String, Object?> value) =>
                FeedComment.fromJson(value, item.ref.source),
          )
          .toList(),
      nextCursor: json['nextCursor']?.toString() ?? '',
      hasMore: json['hasMore'] == true,
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
