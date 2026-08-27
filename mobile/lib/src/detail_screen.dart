import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_controller.dart';
import 'feed_widgets.dart';
import 'models.dart';

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
  late FeedItem _item = widget.initialItem;
  FeedDetail? _detail;
  Object? _error;
  bool _loading = true;
  bool _working = false;
  late bool _following =
      widget.controller.isFollowing(_item.author.ref) || _item.author.following;
  late bool _blocked =
      widget.controller.isBlocked(_item.author.ref) || _item.author.blocked;

  bool get _canLike =>
      widget.controller.supports(_item.ref.source, SourceCapability.like);
  bool get _canFavorite =>
      widget.controller.supports(_item.ref.source, SourceCapability.favorite);
  bool get _canComment =>
      widget.controller.supports(_item.ref.source, SourceCapability.comment);
  bool get _canReply =>
      widget.controller.supports(_item.ref.source, SourceCapability.reply);
  bool get _canFollow =>
      widget.controller.supports(_item.ref.source, SourceCapability.follow);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final detail = await widget.controller.detail(_item.ref);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _item = detail.item;
        _following =
            widget.controller.isFollowing(_item.author.ref) ||
            _item.author.following;
        _blocked =
            widget.controller.isBlocked(_item.author.ref) ||
            _item.author.blocked;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
      await widget.controller.favorite(_item.ref, value);
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
    }, success: value ? '已收藏' : '已取消收藏');
  }

  Future<void> _follow() async {
    final value = !_following;
    await _runAction(() async {
      await widget.controller.follow(_item.author.ref, value);
      if (mounted) setState(() => _following = value);
    }, success: value ? '已关注' : '已取消关注');
  }

  Future<void> _block() async {
    final value = !_blocked;
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('屏蔽此作者？'),
          content: Text('屏蔽后，${_item.author.name} 的内容不会再出现在本地信息流中。'),
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
    await _runAction(
      () async {
        final warning = await widget.controller.block(_item.author.ref, value);
        if (!mounted) return;
        setState(() => _blocked = value);
        if (warning != null) _showMessage(warning);
      },
      success: value ? '已屏蔽此作者' : '已解除屏蔽',
      showSuccess: false,
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
    final detail = await widget.controller.detail(_item.ref);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _item = detail.item;
    });
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
    final comments = detail?.comments ?? const <FeedComment>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(_item.ref.source.label),
        actions: <Widget>[
          PopupMenuButton<String>(
            enabled: !_working && _item.author.ref.id.isNotEmpty,
            onSelected: (String action) {
              if (action == 'block') unawaited(_block());
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'block',
                child: Row(
                  children: <Widget>[
                    Icon(
                      _blocked
                          ? Icons.visibility_outlined
                          : Icons.block_outlined,
                    ),
                    const SizedBox(width: 10),
                    Text(_blocked ? '解除屏蔽' : '屏蔽作者'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
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
                    ],
                  ),
                ),
              ),
              if (comments.isEmpty && !_loading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 10, 16, 36),
                    child: Center(child: Text('还没有加载到评论')),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: comments.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _CommentTile(
                        comment: comments[index],
                        canReply: _canReply && !_working,
                        onReply: () => _reply(comments[index]),
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
  const _MediaCarousel({required this.item, required this.onOpenVideo});

  final FeedItem item;
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
                  onTap: item.kind == 'video'
                      ? () => widget.onOpenVideo(item)
                      : null,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (imageUrl.isNotEmpty)
                        Image.network(
                          imageUrl,
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

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.item,
    required this.body,
    required this.following,
    required this.canFollow,
    required this.working,
    required this.onFollow,
  });

  final FeedItem item;
  final String body;
  final bool following;
  final bool canFollow;
  final bool working;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
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
            Text(body, style: Theme.of(context).textTheme.bodyLarge),
          if (item.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: item.tags
                  .map((String tag) => Chip(label: Text('#$tag')))
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
    required this.canReply,
    required this.onReply,
  });

  final FeedComment comment;
  final bool canReply;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AuthorAvatar(author: comment.author, radius: 17),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  comment.author.name,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(comment.body),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 46,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
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
  WebViewController? _videoController;
  bool _loading = true;
  Object? _error;

  bool get _usesContentPage =>
      widget.media.url.isEmpty && widget.item.ref.source == SourceId.xhs;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      if (_usesContentPage) {
        await widget.controller.xhs.openContentPage(widget.item.ref);
      } else {
        final url = widget.media.url;
        if (url.isEmpty) throw StateError('当前内容没有可播放的视频地址');
        final videoController = WebViewController();
        await videoController.setJavaScriptMode(JavaScriptMode.unrestricted);
        await videoController.setBackgroundColor(Colors.black);
        await videoController.setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (mounted) setState(() => _loading = false);
            },
            onWebResourceError: (WebResourceError error) {
              if (error.isForMainFrame == true && mounted) {
                setState(() => _error = error.description);
              }
            },
          ),
        );
        final escaped = const HtmlEscape(HtmlEscapeMode.attribute).convert(url);
        await videoController.loadHtmlString(
          '''<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;width:100%;height:100%;background:#000}video{width:100%;height:100%;object-fit:contain}</style>
</head><body><video src="$escaped" controls autoplay playsinline></video></body></html>''',
        );
        if (!mounted) return;
        setState(() => _videoController = videoController);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted && _usesContentPage) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _usesContentPage
        ? widget.controller.xhs.webView(key: const Key('xhs-content-webview'))
        : _videoController == null
        ? const SizedBox.expand()
        : WebViewWidget(controller: _videoController!);
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
                child: Text(
                  _error.toString(),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
