import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'feed_widgets.dart';
import 'forum_screen.dart';
import 'models.dart';
import 'network_media.dart';
import 'profile_screen.dart';
import 'social_text.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.controller,
    required this.initialItem,
  });

  final MixsocialController controller;
  final FeedItem initialItem;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late FeedItem _item = widget.initialItem.copyWith(
    favorited:
        widget.initialItem.favorited ||
        widget.controller.isSaved(widget.initialItem),
  );
  FeedDetail? _detail;
  final ScrollController _scrollController = ScrollController();
  List<FeedComment> _comments = const <FeedComment>[];
  Object? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _working = false;
  bool _reverse = false;
  bool _onlyOriginalPoster = false;
  bool _hasMore = false;
  String _nextCursor = '';
  late bool _following =
      widget.controller.isFollowing(_item.author.ref) || _item.author.following;

  bool get _canLike =>
      widget.controller.supports(_item.ref.source, SourceCapability.like);
  bool get _canFavorite => true;
  bool get _canComment =>
      widget.controller.supports(_item.ref.source, SourceCapability.comment);
  bool get _canReply =>
      widget.controller.supports(_item.ref.source, SourceCapability.reply);
  bool get _canFollow =>
      widget.controller.supports(_item.ref.source, SourceCapability.follow);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadMoreNearEnd);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _loadMoreNearEnd() {
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter < 520) {
      unawaited(_loadMore());
    }
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final detail = await widget.controller.detailPage(
        _item.ref,
        reverse: _reverse,
        onlyOriginalPoster: _onlyOriginalPoster,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _item = _resolvedItem(detail.item);
        _comments = widget.controller.prepareComments(detail.comments);
        _hasMore = detail.hasMore;
        _nextCursor = detail.nextCursor;
        _following =
            widget.controller.isFollowing(_item.author.ref) ||
            _item.author.following;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _nextCursor.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.controller.detailPage(
        _item.ref,
        cursor: _nextCursor,
        reverse: _reverse,
        onlyOriginalPoster: _onlyOriginalPoster,
      );
      if (!mounted) return;
      final seen = _comments.map((FeedComment item) => item.ref.id).toSet();
      setState(() {
        _comments = <FeedComment>[
          ..._comments,
          ...widget.controller
              .prepareComments(page.comments)
              .where(
                (FeedComment item) =>
                    item.ref.id.isEmpty || seen.add(item.ref.id),
              ),
        ];
        _hasMore = page.hasMore;
        _nextCursor = page.nextCursor;
      });
    } catch (error) {
      if (mounted) _showMessage('加载更多回复失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  FeedItem _resolvedItem(FeedItem loaded) {
    var value = loaded.ref.id.isEmpty ? _item : loaded;
    if (widget.controller.hideMedia && value.media.isNotEmpty) {
      value = value.copyWith(media: const <MediaItem>[]);
    }
    return value.copyWith(
      favorited: value.favorited || widget.controller.isSaved(value),
    );
  }

  Future<void> _setThreadView({bool? reverse, bool? onlyOriginalPoster}) async {
    setState(() {
      _reverse = reverse ?? _reverse;
      _onlyOriginalPoster = onlyOriginalPoster ?? _onlyOriginalPoster;
      _comments = const <FeedComment>[];
      _detail = null;
      _hasMore = false;
      _nextCursor = '';
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _load();
  }

  Future<void> _like() async {
    final value = !_item.liked;
    await _runAction(() async {
      await widget.controller.like(_item.ref, value);
      if (!mounted) return;
      setState(() {
        _item = _item.copyWith(
          liked: value,
          stats: _item.stats.copyWith(
            likes: _changedCount(_item.stats.likes, _item.liked, value),
          ),
        );
      });
    }, success: value ? '已点赞' : '已取消点赞');
  }

  Future<void> _favorite() async {
    final value = !_item.favorited;
    await _runAction(() async {
      final warning = await widget.controller.favorite(_item, value);
      if (!mounted) return;
      setState(() {
        _item = _item.copyWith(
          favorited: value,
          stats: _item.stats.copyWith(
            favorites: _changedCount(
              _item.stats.favorites,
              _item.favorited,
              value,
            ),
          ),
        );
      });
      if (warning != null) _showMessage(warning);
    }, success: value ? '已收藏' : '已取消收藏');
  }

  Future<void> _follow() async {
    final value = !_following;
    await _runAction(() async {
      await widget.controller.follow(_item.author.ref, value);
      if (mounted) setState(() => _following = value);
    }, success: value ? '已关注' : '已取消关注');
  }

  Future<void> _blockForum() async {
    final forum = _item.forumName;
    if (forum.isEmpty) return;
    final blocked = widget.controller.isForumBlocked(forum);
    if (!blocked) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text('屏蔽 $forum吧？'),
          content: const Text('屏蔽后，这个吧的主题不会再出现在首页、搜索、历史和收藏列表中。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('屏蔽'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await widget.controller.setForumBlocked(forum, !blocked);
    if (!mounted) return;
    _showMessage(blocked ? '已解除屏蔽 $forum吧' : '已屏蔽 $forum吧');
    if (!blocked) Navigator.pop(context);
  }

  void _openForum() {
    if (_item.forumName.isEmpty) return;
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            ForumScreen(controller: widget.controller, forum: _item.forumName),
      ),
    );
  }

  void _openProfile() {
    if (_item.author.ref.source != SourceId.xhs ||
        _item.author.ref.id.isEmpty) {
      return;
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            ProfileScreen(controller: widget.controller, author: _item.author),
      ),
    );
  }

  void _openTopic(String topic) {
    widget.controller.requestSearchNavigation(SourceId.xhs, topic);
  }

  void _openFloorReplies(FeedComment comment) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _FloorRepliesScreen(
          controller: widget.controller,
          comment: comment,
          originalPosterId: _item.author.id,
        ),
      ),
    );
  }

  Future<void> _comment() async {
    final body = await _compose(title: '发表评论', hint: '友善交流，理性表达');
    if (body == null || !mounted) return;
    await _runAction(() async {
      await widget.controller.comment(_item.ref, body);
      await _reloadAfterInteraction();
    }, success: '评论已发送');
  }

  Future<void> _reply(FeedComment comment) async {
    final body = await _compose(
      title: '回复 ${comment.author.name}',
      hint: '输入回复内容',
    );
    if (body == null || !mounted) return;
    await _runAction(() async {
      await widget.controller.reply(_item.ref, comment.ref, body);
      await _reloadAfterInteraction();
    }, success: '回复已发送');
  }

  Future<void> _reloadAfterInteraction() async {
    await _load();
  }

  Future<String?> _compose({
    required String title,
    required String hint,
  }) async {
    final textController = TextEditingController();
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          18,
          18,
          MediaQuery.viewInsetsOf(context).bottom + 18,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              key: const Key('comment-input'),
              controller: textController,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              maxLength: 500,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final value = textController.text.trim();
                  if (value.isNotEmpty) Navigator.pop(context, value);
                },
                child: const Text('发送'),
              ),
            ),
          ],
        ),
      ),
    );
    textController.dispose();
    return result;
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    required String success,
    bool showSuccess = true,
  }) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
      if (mounted && showSuccess) _showMessage(success);
    } catch (error) {
      if (mounted) _showMessage(error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _showMessage(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  int _changedCount(int current, bool oldValue, bool newValue) {
    if (oldValue == newValue) return current;
    return (current + (newValue ? 1 : -1)).clamp(0, 1 << 31);
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final comments = _comments;
    final tiebaThread = _item.ref.source == SourceId.tieba;
    return Scaffold(
      appBar: AppBar(
        title: Text(_item.ref.source.label),
        actions: <Widget>[
          if (tiebaThread)
            PopupMenuButton<String>(
              enabled: !_working && !_loading,
              onSelected: (String action) {
                switch (action) {
                  case 'reverse':
                    unawaited(_setThreadView(reverse: !_reverse));
                    break;
                  case 'onlyOriginalPoster':
                    unawaited(
                      _setThreadView(onlyOriginalPoster: !_onlyOriginalPoster),
                    );
                    break;
                  case 'blockForum':
                    unawaited(_blockForum());
                    break;
                  case 'openForum':
                    _openForum();
                    break;
                }
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                CheckedPopupMenuItem<String>(
                  value: 'reverse',
                  checked: _reverse,
                  child: const Text('倒序浏览'),
                ),
                CheckedPopupMenuItem<String>(
                  value: 'onlyOriginalPoster',
                  checked: _onlyOriginalPoster,
                  child: const Text('只看楼主'),
                ),
                if (_item.forumName.isNotEmpty)
                  PopupMenuItem<String>(
                    value: 'openForum',
                    child: Text('进入 ${_item.forumName}吧'),
                  ),
                if (_item.forumName.isNotEmpty)
                  PopupMenuItem<String>(
                    value: 'blockForum',
                    child: Text(
                      widget.controller.isForumBlocked(_item.forumName)
                          ? '解除屏蔽 ${_item.forumName}吧'
                          : '屏蔽 ${_item.forumName}吧',
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            if (_loading)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (_error != null && detail == null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _DetailFailure(error: _error.toString(), onRetry: _load),
              )
            else ...<Widget>[
              if (_item.media.isNotEmpty)
                SliverToBoxAdapter(
                  child: _MediaCarousel(
                    item: _item,
                    onOpenImage: (MediaItem media) => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => _ImageScreen(
                          source: _item.ref.source,
                          media: media,
                        ),
                      ),
                    ),
                    onOpenVideo: (MediaItem media) => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => _VideoScreen(
                          controller: widget.controller,
                          item: _item,
                          media: media,
                        ),
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: _DetailHeader(
                  item: _item,
                  body: detail?.body ?? _item.summary,
                  following: _following,
                  canFollow: _canFollow,
                  working: _working,
                  onFollow: _follow,
                  onForumTap: _openForum,
                  onAuthorTap: _openProfile,
                  onTopicTap: _openTopic,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
                  child: Row(
                    children: <Widget>[
                      Text(
                        '评论',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${comments.length}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const Spacer(),
                      if (_onlyOriginalPoster)
                        const Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text('只看楼主'),
                        ),
                      if (_reverse) ...<Widget>[
                        const SizedBox(width: 6),
                        const Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text('倒序'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (comments.isEmpty && !_loading)
                const SliverToBoxAdapter(
                  child: AppStateView(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: '还没有评论',
                    message: '这里暂时没有加载到回复，稍后可以下拉刷新再看看。',
                    compact: true,
                  ),
                )
              else
                SliverList.builder(
                  itemCount: comments.length,
                  itemBuilder: (BuildContext context, int index) {
                    final comment = comments[index];
                    return _CommentTile(
                      comment: comment,
                      originalPosterId: _item.author.id,
                      density: widget.controller.density,
                      canReply: _canReply && !_working,
                      onReply: () => _reply(comment),
                      onTopicTap: _item.ref.source == SourceId.xhs
                          ? _openTopic
                          : null,
                      onOpenReplies:
                          widget.controller.supportsFloorReplies(
                                _item.ref.source,
                              ) &&
                              comment.replyCount > 0
                          ? () => _openFloorReplies(comment)
                          : null,
                    );
                  },
                ),
              if (_loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                  ),
                )
              else if (_hasMore)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
                    child: OutlinedButton(
                      onPressed: _loadMore,
                      child: const Text('加载更多回复'),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 92)),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _InteractionBar(
        item: _item,
        working: _working,
        canLike: _canLike,
        canFavorite: _canFavorite,
        canComment: _canComment,
        onLike: _like,
        onFavorite: _favorite,
        onComment: _comment,
      ),
    );
  }
}

class _MediaCarousel extends StatefulWidget {
  const _MediaCarousel({
    required this.item,
    required this.onOpenImage,
    required this.onOpenVideo,
  });

  final FeedItem item;
  final ValueChanged<MediaItem> onOpenImage;
  final ValueChanged<MediaItem> onOpenVideo;

  @override
  State<_MediaCarousel> createState() => _MediaCarouselState();
}

class _MediaCarouselState extends State<_MediaCarousel> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final media = widget.item.media;
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          PageView.builder(
            itemCount: media.length,
            onPageChanged: (int value) => setState(() => _page = value),
            itemBuilder: (BuildContext context, int index) {
              final item = media[index];
              final imageUrl = item.displayUrl;
              return Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: InkWell(
                  onTap: () => item.kind == 'video'
                      ? widget.onOpenVideo(item)
                      : widget.onOpenImage(item),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (imageUrl.isNotEmpty)
                        SourceNetworkImage(
                          url: imageUrl,
                          source: widget.item.ref.source,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) =>
                              const _MediaUnavailable(),
                        )
                      else
                        const _MediaUnavailable(),
                      if (item.kind == 'video')
                        const Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 42,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          Positioned(
            left: 12,
            top: 12,
            child: SourceBadge(source: widget.item.ref.source),
          ),
          if (media.length > 1)
            Positioned(
              right: 12,
              top: 12,
              child: Chip(
                visualDensity: VisualDensity.compact,
                label: Text('${_page + 1}/${media.length}'),
              ),
            ),
        ],
      ),
    );
  }
}

class _MediaUnavailable extends StatelessWidget {
  const _MediaUnavailable();

  @override
  Widget build(BuildContext context) => Center(
    child: Icon(
      Icons.broken_image_outlined,
      size: 54,
      color: Theme.of(context).colorScheme.outline,
    ),
  );
}

class _ImageScreen extends StatelessWidget {
  const _ImageScreen({required this.source, required this.media});

  final SourceId source;
  final MediaItem media;

  @override
  Widget build(BuildContext context) {
    final url = media.url.isNotEmpty ? media.url : media.displayUrl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
        title: const Text('查看图片'),
      ),
      body: Center(
        child: url.isEmpty
            ? const _MediaUnavailable()
            : InteractiveViewer(
                minScale: 0.8,
                maxScale: 5,
                child: SourceNetworkImage(
                  url: url,
                  source: source,
                  fit: BoxFit.contain,
                  maxDimension: 4096,
                  errorBuilder: (_, _, _) => const _MediaUnavailable(),
                ),
              ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.item,
    required this.body,
    required this.following,
    required this.canFollow,
    required this.working,
    required this.onFollow,
    required this.onForumTap,
    required this.onAuthorTap,
    required this.onTopicTap,
  });

  final FeedItem item;
  final String body;
  final bool following;
  final bool canFollow;
  final bool working;
  final VoidCallback onFollow;
  final VoidCallback onForumTap;
  final VoidCallback onAuthorTap;
  final ValueChanged<String> onTopicTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: InkWell(
                  onTap: item.ref.source == SourceId.xhs ? onAuthorTap : null,
                  borderRadius: BorderRadius.circular(28),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: <Widget>[
                        AuthorAvatar(author: item.author, radius: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            item.author.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (canFollow)
                following
                    ? OutlinedButton(
                        onPressed: working ? null : onFollow,
                        child: const Text('已关注'),
                      )
                    : FilledButton(
                        onPressed: working ? null : onFollow,
                        child: const Text('关注'),
                      ),
            ],
          ),
          const SizedBox(height: 18),
          if (item.title.isNotEmpty) ...<Widget>[
            Text(
              item.title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
          ],
          if (body.isNotEmpty)
            SocialRichText(
              text: body,
              source: item.ref.source,
              style: Theme.of(context).textTheme.bodyLarge,
              onTopicTap: item.ref.source == SourceId.xhs ? onTopicTap : null,
            ),
          if (item.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: item.tags
                  .map(
                    (String tag) => ActionChip(
                      label: Text('#$tag'),
                      onPressed: item.ref.source == SourceId.xhs
                          ? () => onTopicTap(tag)
                          : item.forumName.isEmpty
                          ? null
                          : onForumTap,
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: <Widget>[
              CompactStat(icon: Icons.favorite_border, value: item.stats.likes),
              CompactStat(
                icon: Icons.chat_bubble_outline,
                value: item.stats.comments,
              ),
              CompactStat(
                icon: Icons.bookmark_border,
                value: item.stats.favorites,
              ),
              if (item.stats.views > 0)
                CompactStat(
                  icon: Icons.visibility_outlined,
                  value: item.stats.views,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.originalPosterId,
    required this.density,
    required this.canReply,
    required this.onReply,
    this.onOpenReplies,
    this.onTopicTap,
  });

  final FeedComment comment;
  final String originalPosterId;
  final FeedDensity density;
  final bool canReply;
  final VoidCallback onReply;
  final VoidCallback? onOpenReplies;
  final ValueChanged<String>? onTopicTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        density == FeedDensity.compact ? 5 : 8,
        16,
        density == FeedDensity.comfortable ? 18 : 12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AuthorAvatar(author: comment.author, radius: 17),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        comment.author.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    if (comment.author.id.isNotEmpty &&
                        comment.author.id == originalPosterId) ...<Widget>[
                      const SizedBox(width: 6),
                      const Badge(label: Text('楼主')),
                    ],
                    const Spacer(),
                    Text(
                      <String>[
                        if (comment.floor > 0) '${comment.floor}楼',
                        if (comment.publishedAt != null)
                          _commentTime(comment.publishedAt!),
                      ].join(' · '),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SocialRichText(
                  text: comment.body,
                  source: comment.ref.source,
                  onTopicTap: onTopicTap,
                ),
                if (comment.media.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 92,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: comment.media.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (BuildContext context, int index) {
                        final media = comment.media[index];
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox.square(
                            dimension: 92,
                            child: SourceNetworkImage(
                              url: media.displayUrl,
                              source: comment.ref.source,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => ColoredBox(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                child: const Icon(Icons.broken_image_outlined),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                if (comment.replies.isNotEmpty ||
                    onOpenReplies != null) ...<Widget>[
                  const SizedBox(height: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          for (final reply in comment.replies)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: SocialRichText(
                                text: reply.body,
                                source: reply.ref.source,
                                onTopicTap: onTopicTap,
                                leading: <InlineSpan>[
                                  TextSpan(
                                    text: '${reply.author.name}：',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (onOpenReplies != null)
                            TextButton(
                              onPressed: onOpenReplies,
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                              child: Text(
                                comment.replyCount > comment.replies.length
                                    ? '查看全部 ${comment.replyCount} 条回复'
                                    : '查看楼中楼',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                Row(
                  children: <Widget>[
                    CompactStat(
                      icon: Icons.thumb_up_alt_outlined,
                      value: comment.likes,
                    ),
                    if (canReply) ...<Widget>[
                      const SizedBox(width: 12),
                      TextButton(onPressed: onReply, child: const Text('回复')),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FloorRepliesScreen extends StatefulWidget {
  const _FloorRepliesScreen({
    required this.controller,
    required this.comment,
    required this.originalPosterId,
  });

  final MixsocialController controller;
  final FeedComment comment;
  final String originalPosterId;

  @override
  State<_FloorRepliesScreen> createState() => _FloorRepliesScreenState();
}

class _FloorRepliesScreenState extends State<_FloorRepliesScreen> {
  final ScrollController _scrollController = ScrollController();
  late List<FeedComment> _replies = widget.controller.prepareComments(
    widget.comment.replies,
  );
  String _nextCursor = '';
  Object? _error;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.extentAfter < 420) unawaited(_loadMore());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.controller.floorReplies(widget.comment.ref);
      if (!mounted) return;
      setState(() {
        _replies = widget.controller.prepareComments(page.comments);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _nextCursor.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.controller.floorReplies(
        widget.comment.ref,
        cursor: _nextCursor,
      );
      if (!mounted) return;
      final seen = _replies.map((FeedComment item) => item.ref.id).toSet();
      final additions = widget.controller.prepareComments(
        page.comments.where(
          (FeedComment item) => item.ref.id.isEmpty || seen.add(item.ref.id),
        ),
      );
      setState(() {
        _replies = <FeedComment>[..._replies, ...additions];
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore && additions.isNotEmpty;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.comment.floor > 0 ? '${widget.comment.floor}楼的回复' : '楼中楼回复',
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            if (_loading)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            SliverToBoxAdapter(
              child: _CommentTile(
                comment: widget.comment.copyWith(
                  replies: const <FeedComment>[],
                ),
                originalPosterId: widget.originalPosterId,
                density: widget.controller.density,
                canReply: false,
                onReply: () {},
                onTopicTap: widget.comment.ref.source == SourceId.xhs
                    ? (String topic) => widget.controller
                          .requestSearchNavigation(SourceId.xhs, topic)
                    : null,
              ),
            ),
            const SliverToBoxAdapter(child: Divider(height: 1)),
            if (_error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('读取全部回复失败：$_error'),
                ),
              ),
            if (!_loading && _replies.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('没有加载到楼中楼回复')),
                ),
              )
            else
              SliverList.builder(
                itemCount: _replies.length,
                itemBuilder: (BuildContext context, int index) => _CommentTile(
                  comment: _replies[index],
                  originalPosterId: widget.originalPosterId,
                  density: widget.controller.density,
                  canReply: false,
                  onReply: () {},
                  onTopicTap: _replies[index].ref.source == SourceId.xhs
                      ? (String topic) => widget.controller
                            .requestSearchNavigation(SourceId.xhs, topic)
                      : null,
                ),
              ),
            if (_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (_hasMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton(
                    onPressed: _loadMore,
                    child: const Text('加载更多楼中楼'),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }
}

String _commentTime(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  if (now.year == local.year &&
      now.month == local.month &&
      now.day == local.day) {
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  return '${local.month}-${local.day}';
}

class _InteractionBar extends StatelessWidget {
  const _InteractionBar({
    required this.item,
    required this.working,
    required this.canLike,
    required this.canFavorite,
    required this.canComment,
    required this.onLike,
    required this.onFavorite,
    required this.onComment,
  });

  final FeedItem item;
  final bool working;
  final bool canLike;
  final bool canFavorite;
  final bool canComment;
  final VoidCallback onLike;
  final VoidCallback onFavorite;
  final VoidCallback onComment;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 10,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: _ActionButton(
                  icon: item.liked ? Icons.favorite : Icons.favorite_border,
                  label: compactCount(item.stats.likes),
                  selected: item.liked,
                  onPressed: canLike && !working ? onLike : null,
                ),
              ),
              Expanded(
                child: _ActionButton(
                  icon: item.favorited ? Icons.bookmark : Icons.bookmark_border,
                  label: compactCount(item.stats.favorites),
                  selected: item.favorited,
                  onPressed: canFavorite && !working ? onFavorite : null,
                ),
              ),
              Expanded(
                child: _ActionButton(
                  icon: Icons.chat_bubble_outline,
                  label: '评论',
                  onPressed: canComment && !working ? onComment : null,
                ),
              ),
              if (working)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Theme.of(context).colorScheme.primary : null;
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: color),
      label: Text(label, maxLines: 1, style: TextStyle(color: color)),
    );
  }
}

class _DetailFailure extends StatelessWidget {
  const _DetailFailure({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppStateView(
      icon: Icons.error_outline_rounded,
      iconColor: Theme.of(context).colorScheme.error,
      title: '帖子加载失败',
      message: error,
      actionLabel: '重新加载',
      onAction: onRetry,
    );
  }
}

class _VideoScreen extends StatefulWidget {
  const _VideoScreen({
    required this.controller,
    required this.item,
    required this.media,
  });

  final MixsocialController controller;
  final FeedItem item;
  final MediaItem media;

  @override
  State<_VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<_VideoScreen> {
  VideoPlayerController? _playerController;
  bool _loading = true;
  bool _webFallback = false;
  Object? _error;

  bool get _usesContentPage =>
      _webFallback ||
      (widget.media.url.isEmpty && widget.item.ref.source == SourceId.xhs);

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    unawaited(_playerController?.dispose());
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      if (_usesContentPage) {
        await widget.controller.xhs.openContentPage(widget.item.ref);
      } else {
        final playerController = await _initializeNativePlayer();
        if (!mounted) {
          await playerController.dispose();
          return;
        }
        setState(() => _playerController = playerController);
      }
    } catch (error) {
      if (widget.item.ref.source == SourceId.xhs && !_webFallback) {
        try {
          await widget.controller.xhs.openContentPage(widget.item.ref);
          if (mounted) {
            setState(() {
              _webFallback = true;
              _error = null;
            });
          }
        } catch (fallbackError) {
          if (mounted) setState(() => _error = fallbackError);
        }
      } else if (mounted) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<VideoPlayerController> _initializeNativePlayer() async {
    final preferred = mediaUri(widget.media.url, preferHttps: true);
    final original = mediaUri(widget.media.url);
    if (preferred == null) throw StateError('当前内容没有有效的可播放地址');
    final attempts = <({Uri uri, Map<String, String> headers})>[
      (
        uri: preferred,
        headers: mediaRequestHeaders(widget.item.ref.source, video: true),
      ),
      (uri: preferred, headers: const <String, String>{}),
      if (original != null && original != preferred)
        (
          uri: original,
          headers: mediaRequestHeaders(widget.item.ref.source, video: true),
        ),
    ];
    Object? lastError;
    for (final attempt in attempts) {
      final playerController = VideoPlayerController.networkUrl(
        attempt.uri,
        httpHeaders: attempt.headers,
      );
      try {
        await playerController.initialize();
        await playerController.play();
        return playerController;
      } on Object catch (error) {
        lastError = error;
        await playerController.dispose();
      }
    }
    throw StateError('视频播放器初始化失败：$lastError');
  }

  Future<void> _retry() async {
    final previous = _playerController;
    _playerController = null;
    await previous?.dispose();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _prepare();
  }

  @override
  Widget build(BuildContext context) {
    final player = _playerController;
    final child = _usesContentPage
        ? widget.controller.xhs.webView(key: const Key('xhs-content-webview'))
        : player == null
        ? const SizedBox.expand()
        : _VideoPlayerSurface(controller: player);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
        title: const Text('视频'),
      ),
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: child),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      _error.toString(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => unawaited(_retry()),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试播放'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VideoPlayerSurface extends StatelessWidget {
  const _VideoPlayerSurface({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (BuildContext context, VideoPlayerValue value, Widget? child) {
        final ratio = value.aspectRatio > 0 ? value.aspectRatio : 16 / 9;
        return Center(
          child: AspectRatio(
            aspectRatio: ratio,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(
                value.isPlaying ? controller.pause() : controller.play(),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  VideoPlayer(controller),
                  if (value.isBuffering)
                    const Center(child: CircularProgressIndicator()),
                  if (!value.isPlaying && !value.isBuffering)
                    const Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 46,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: VideoProgressIndicator(
                      controller,
                      allowScrubbing: true,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      colors: const VideoProgressColors(
                        playedColor: Colors.redAccent,
                        bufferedColor: Colors.white38,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
