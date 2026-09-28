import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_controller.dart';
import 'comment_composer.dart';
import 'comment_drafts.dart';
import 'design_system.dart';
import 'detail_content_tools.dart';
import 'feed_widgets.dart';
import 'forum_screen.dart';
import 'media_preview_screen.dart';
import 'models.dart';
import 'media_tools.dart';
import 'network_media.dart';
import 'profile_screen.dart';
import 'reading_preferences.dart';
import 'reading_state_store.dart';
import 'social_text.dart';

export 'media_preview_screen.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.controller,
    required this.initialItem,
    this.readingStore,
    this.preferencesStore,
    this.draftStore,
  });

  final MixsocialController controller;
  final FeedItem initialItem;
  final ReadingStateStore? readingStore;
  final ReadingPreferencesStore? preferencesStore;
  final CommentDraftStore? draftStore;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late FeedItem _item = widget.initialItem.copyWith(
    favorited:
        widget.initialItem.favorited ||
        (widget.initialItem.ref.source != SourceId.xhs &&
            widget.controller.isSaved(widget.initialItem)),
  );
  FeedDetail? _detail;
  final ScrollController _scrollController = ScrollController();
  late final ReadingStateStore _readingStore =
      widget.readingStore ?? ReadingStateStore();
  late final ReadingPreferencesStore _preferencesStore =
      widget.preferencesStore ?? ReadingPreferencesStore();
  late final CommentDraftStore _drafts =
      widget.draftStore ?? CommentDraftStore();
  ReadingPreferences _readingPreferences = const ReadingPreferences();
  final Map<String, GlobalKey> _commentKeys = <String, GlobalKey>{};
  final Map<String, int> _commentPages = <String, int>{};
  DateTime? _lastReadingSave;
  bool _restoringPosition = true;
  bool _completed = false;
  String _pageCursor = '';
  int _currentPage = 1;
  int _totalPages = 0;
  List<FeedComment> _comments = const <FeedComment>[];
  final Map<String, FeedComment> _commentLikeUpdates = <String, FeedComment>{};
  final Set<String> _pendingCommentLikes = <String>{};
  Object? _error;
  Object? _paginationError;
  bool _loading = true;
  bool _loadingMore = false;
  bool _working = false;
  bool _reverse = false;
  bool _onlyOriginalPoster = false;
  bool _hasMore = false;
  String _nextCursor = '';
  int _requestGeneration = 0;
  bool? _readLater;
  bool _readLaterWorking = true;
  late bool _following = widget.controller.isFollowing(
    _item.author.ref,
    fallback: _item.author.following,
  );

  bool get _canLike =>
      widget.controller.supports(_item.ref.source, SourceCapability.like);
  bool get _canFavorite => true;
  bool get _canComment =>
      _item.ref.source == SourceId.tieba ||
      widget.controller.supports(_item.ref.source, SourceCapability.comment);
  bool get _canReply =>
      _item.ref.source == SourceId.tieba ||
      widget.controller.supports(_item.ref.source, SourceCapability.reply);
  bool get _canLikeComment => widget.controller.supports(
    _item.ref.source,
    SourceCapability.commentLike,
  );
  bool get _canFollow =>
      widget.controller.supports(_item.ref.source, SourceCapability.follow);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncFollowing);
    _scrollController.addListener(_loadMoreNearEnd);
    _scrollController.addListener(_scheduleReadingSave);
    unawaited(_restoreReadingAndLoad());
    unawaited(_loadReadLater());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFollowing);
    if (!_restoringPosition && _detail != null) {
      unawaited(
        _readingStore
            .save(_item.key, _captureReadingPosition())
            .catchError((Object _) {}),
      );
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _syncFollowing() {
    final value = widget.controller.isFollowing(
      _item.author.ref,
      fallback: _item.author.following,
    );
    if (mounted && value != _following) {
      setState(() => _following = value);
    }
  }

  void _loadMoreNearEnd() {
    if (!_restoringPosition &&
        _paginationError == null &&
        _error == null &&
        _scrollController.hasClients &&
        _scrollController.position.extentAfter < 520) {
      unawaited(_loadMore());
    }
  }

  Future<void> _restoreReadingAndLoad() async {
    ReadingState? previous;
    try {
      previous = await _readingStore.get(_item.key);
      final preferences = await _preferencesStore.read();
      if (!mounted) return;
      setState(() {
        _readingPreferences = preferences;
        _completed = previous?.completed ?? false;
        _reverse = previous?.reverse ?? false;
        _onlyOriginalPoster = previous?.onlyOriginalPoster ?? false;
        if (_item.ref.source == SourceId.tieba && (previous?.page ?? 1) > 1) {
          _pageCursor = '${previous!.page}';
        }
      });
    } catch (_) {
      // Reading preferences must never prevent opening a remote thread.
    }
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    if (previous != null && _error == null) await _restorePosition(previous);
    if (!mounted) return;
    setState(() => _restoringPosition = false);
    _scheduleReadingSave();
  }

  Future<void> _restorePosition(ReadingState previous) async {
    if (previous.offset == 0 && previous.anchorId.isEmpty) return;
    final generation = _requestGeneration;
    // Web cursors are session-dependent. Re-read a bounded number of pages to
    // locate the real comment instead of reusing a stale cursor or percentage.
    for (
      var attempt = 0;
      previous.anchorId.isNotEmpty &&
          !_comments.any((comment) => comment.ref.id == previous.anchorId) &&
          _item.ref.source == SourceId.xhs &&
          _hasMore &&
          attempt < 4;
      attempt++
    ) {
      await _loadMore();
      if (!mounted ||
          generation != _requestGeneration ||
          _paginationError != null) {
        return;
      }
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        generation != _requestGeneration ||
        !_scrollController.hasClients) {
      return;
    }
    if (previous.anchorId.isEmpty) {
      _scrollController.jumpTo(
        previous.offset.clamp(0, _scrollController.position.maxScrollExtent),
      );
      return;
    }
    if (!_comments.any((comment) => comment.ref.id == previous.anchorId)) {
      _showMessage('原阅读回复暂未找到，已打开第 $_currentPage 页；可继续加载查找。');
      return;
    }
    // Sliver children are lazy. Walk viewport-sized chunks until the saved
    // concrete anchor is laid out, then restore its measured local offset.
    for (var attempt = 0; attempt < 60; attempt++) {
      final target = _commentKeys[previous.anchorId]?.currentContext
          ?.findRenderObject();
      if (target is RenderBox && target.hasSize) {
        final base = RenderAbstractViewport.of(
          target,
        ).getOffsetToReveal(target, 0).offset;
        _scrollController.jumpTo(
          (base + previous.offset).clamp(
            0,
            _scrollController.position.maxScrollExtent,
          ),
        );
        _showMessage('已恢复上次阅读位置');
        return;
      }
      final position = _scrollController.position;
      final next = (position.pixels + position.viewportDimension * .75).clamp(
        0,
        position.maxScrollExtent,
      );
      if (next == position.pixels) break;
      _scrollController.jumpTo(next.toDouble());
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          generation != _requestGeneration ||
          !_scrollController.hasClients) {
        return;
      }
    }
    _showMessage('已打开上次阅读页；回复布局有变化，请继续定位。');
  }

  ReadingState _captureReadingPosition() {
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    FeedComment? anchor;
    var anchorOffset = 0.0;
    for (final comment in _comments) {
      final render = _commentKeys[comment.ref.id]?.currentContext
          ?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) continue;
      final start = RenderAbstractViewport.of(
        render,
      ).getOffsetToReveal(render, 0).offset;
      if (start <= offset + 80 && start + render.size.height > offset) {
        anchor = comment;
        anchorOffset = start;
        break;
      }
    }
    return ReadingState(
      page: anchor == null
          ? _currentPage
          : _commentPages[anchor.ref.id] ?? _currentPage,
      offset: offset - anchorOffset,
      anchorId: anchor?.ref.id ?? '',
      floor: anchor?.floor ?? 0,
      reverse: _reverse,
      onlyOriginalPoster: _onlyOriginalPoster,
      completed: _completed,
      updatedAt: DateTime.now(),
    );
  }

  void _scheduleReadingSave() {
    if (_restoringPosition || _loading || _detail == null) return;
    final now = DateTime.now();
    if (_lastReadingSave != null &&
        now.difference(_lastReadingSave!).inMilliseconds < 700) {
      return;
    }
    _lastReadingSave = now;
    unawaited(
      _readingStore
          .save(_item.key, _captureReadingPosition())
          .catchError((Object _) {}),
    );
  }

  Future<void> _toggleCompleted() async {
    try {
      await _readingStore.setCompleted(_item.key, !_completed);
      if (!mounted) return;
      setState(() => _completed = !_completed);
      _showMessage(_completed ? '已标记已读，稍后阅读列表保留记录' : '已标记未读');
    } catch (error) {
      if (mounted) _showMessage('更新阅读状态失败：$error', error: true);
    }
  }

  Future<void> _showReadingPreferences() async {
    var draft = _readingPreferences;
    final result = await showModalBottomSheet<ReadingPreferences>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('阅读设置', style: Theme.of(context).textTheme.titleLarge),
                Text('字号 ${draft.fontSize.round()}'),
                Slider(
                  key: const Key('reading-font-size'),
                  value: draft.fontSize,
                  min: 12,
                  max: 26,
                  divisions: 14,
                  onChanged: (value) =>
                      update(() => draft = draft.copyWith(fontSize: value)),
                ),
                Text('行距 ${draft.lineHeight.toStringAsFixed(1)}'),
                Slider(
                  key: const Key('reading-line-height'),
                  value: draft.lineHeight,
                  min: 1.2,
                  max: 2.2,
                  divisions: 10,
                  onChanged: (value) =>
                      update(() => draft = draft.copyWith(lineHeight: value)),
                ),
                Text(
                  '这是正文和评论的阅读预览。\n设置对贴吧、小红书和知乎共用。',
                  style: TextStyle(
                    fontSize: draft.fontSize,
                    height: draft.lineHeight,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    TextButton(
                      onPressed: () =>
                          update(() => draft = const ReadingPreferences()),
                      child: const Text('恢复默认'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, draft),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      await _preferencesStore.save(result);
      if (mounted) setState(() => _readingPreferences = result);
    } catch (error) {
      if (mounted) _showMessage('保存阅读设置失败：$error', error: true);
    }
  }

  Future<void> _choosePage() async {
    var input = '$_currentPage';
    final maxPage = _totalPages > 0 ? _totalPages : 100000;
    String? error;
    final page = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('跳转页码'),
          content: TextFormField(
            key: const Key('thread-page-input'),
            initialValue: input,
            onChanged: (value) => input = value,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _totalPages > 0
                  ? '第 1～$_totalPages 页'
                  : '总页数未知（最多 100000 页）',
              errorText: error,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final value = int.tryParse(input);
                if (value == null || value < 1 || value > maxPage) {
                  update(() => error = '请输入 1～$maxPage 的整数');
                  return;
                }
                Navigator.pop(context, value);
              },
              child: const Text('跳转'),
            ),
          ],
        ),
      ),
    );
    if (page == null || !mounted) return;
    final previousCursor = _pageCursor;
    _pageCursor = page == 1 ? '' : '$page';
    await _load();
    if (!mounted) return;
    if (_error != null) {
      _pageCursor = previousCursor;
      return;
    }
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _scheduleReadingSave();
  }

  Future<void> _shareContent() async {
    final link = contentLink(_item.ref);
    if (link == null) return;
    try {
      await MediaTools.shareText(link, title: _item.title);
    } catch (error) {
      if (mounted) _showMessage('分享失败：$error', error: true);
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_requestGeneration;
    final likeSnapshot = Map<String, FeedComment>.of(_commentLikeUpdates);
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _paginationError = null;
    });
    try {
      final detail = await widget.controller.detailPage(
        _item.ref,
        cursor: _pageCursor,
        reverse: _reverse,
        onlyOriginalPoster: _onlyOriginalPoster,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _detail = detail;
        _item = _resolvedItem(detail.item);
        _comments = widget.controller.prepareComments(detail.comments);
        _currentPage = detail.currentPage > 1
            ? detail.currentPage
            : int.tryParse(_pageCursor) ?? 1;
        _totalPages = detail.totalPages;
        _commentPages.clear();
        for (final comment in _comments) {
          _commentPages[comment.ref.id] = _currentPage;
        }
        _reconcileCommentLikes(_comments, _commentLikeUpdates, likeSnapshot);
        _hasMore = detail.hasMore && detail.nextCursor.isNotEmpty;
        _nextCursor = detail.nextCursor;
        _following = widget.controller.isFollowing(
          _item.author.ref,
          fallback: _item.author.following,
        );
      });
    } catch (error) {
      if (mounted && generation == _requestGeneration) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadMore() async {
    if (!mounted ||
        _loading ||
        _loadingMore ||
        !_hasMore ||
        _nextCursor.isEmpty) {
      return;
    }
    final generation = _requestGeneration;
    final cursor = _nextCursor;
    setState(() {
      _loadingMore = true;
      _paginationError = null;
    });
    try {
      final page = await widget.controller.detailPage(
        _item.ref,
        cursor: cursor,
        reverse: _reverse,
        onlyOriginalPoster: _onlyOriginalPoster,
      );
      if (!mounted || generation != _requestGeneration) return;
      final seen = _comments.map((FeedComment item) => item.ref.id).toSet();
      setState(() {
        for (final comment in page.comments) {
          _commentPages.putIfAbsent(
            comment.ref.id,
            () => page.currentPage > 1
                ? page.currentPage
                : int.tryParse(cursor) ?? 1,
          );
        }
        if (page.totalPages > 0) _totalPages = page.totalPages;
        _comments = <FeedComment>[
          ..._comments,
          ...widget.controller
              .prepareComments(page.comments)
              .where(
                (FeedComment item) =>
                    item.ref.id.isEmpty || seen.add(item.ref.id),
              ),
        ];
        _hasMore =
            page.hasMore &&
            page.nextCursor.isNotEmpty &&
            page.nextCursor != cursor;
        _nextCursor = page.nextCursor;
      });
    } catch (error) {
      if (mounted && generation == _requestGeneration) {
        setState(() => _paginationError = error);
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _loadReadLater() async {
    if (!mounted) return;
    setState(() => _readLaterWorking = true);
    try {
      final value = await widget.controller.isReadLater(_item);
      if (mounted) setState(() => _readLater = value);
    } catch (error) {
      if (mounted) _showMessage('读取稍后阅读状态失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _readLaterWorking = false);
    }
  }

  Future<void> _toggleReadLater() async {
    if (!mounted || _readLaterWorking) return;
    final current = _readLater;
    if (current == null) {
      await _loadReadLater();
      return;
    }
    setState(() => _readLaterWorking = true);
    try {
      await widget.controller.setReadLater(_item, !current);
      if (!mounted) return;
      setState(() => _readLater = !current);
      _showMessage(current ? '已移出稍后阅读' : '已加入稍后阅读，可在“我的”中查看');
    } catch (error) {
      if (mounted) _showMessage('更新稍后阅读失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _readLaterWorking = false);
    }
  }

  Future<void> _copyContent({required bool link}) async {
    final value = link
        ? contentLink(_item.ref)
        : contentText(_item, body: _detail?.body);
    if (value == null || value.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) _showMessage(link ? '帖子链接已复制' : '正文已复制');
    } catch (error) {
      if (mounted) _showMessage('复制失败：$error', error: true);
    }
  }

  FeedItem _resolvedItem(FeedItem loaded) {
    var value = loaded.ref.id.isEmpty ? _item : loaded;
    if (widget.controller.hideMedia && value.media.isNotEmpty) {
      value = value.copyWith(media: const <MediaItem>[]);
    }
    return value.copyWith(
      favorited:
          value.favorited ||
          (value.ref.source != SourceId.xhs &&
              widget.controller.isSaved(value)),
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
      _pageCursor = '';
      _currentPage = 1;
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
    await _runAction(
      () async {
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
        _showMessage(warning ?? (value ? '已收藏' : '已取消收藏'));
      },
      success: '',
      showSuccess: false,
    );
  }

  Future<void> _follow() async {
    final value = !_following;
    await _runAction(
      () async {
        final warning = await widget.controller.follow(_item.author.ref, value);
        if (!mounted) return;
        setState(() => _following = value);
        _showMessage(warning ?? (value ? '已关注' : '已取消关注'));
      },
      success: '',
      showSuccess: false,
    );
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

  void _openTiebaInteraction() {
    if (_item.ref.source != SourceId.tieba) return;
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            _TiebaInteractionScreen(controller: widget.controller, item: _item),
      ),
    );
  }

  void _openProfile() {
    if (!widget.controller.supportsProfile(_item.author.ref.source) ||
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

  void _openImage(SourceId source, MediaItem media, {List<MediaItem>? items}) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MediaPreviewScreen(
          source: source,
          media: media,
          mediaItems: items ?? _item.media,
        ),
      ),
    );
  }

  void _openFloorReplies(FeedComment comment) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _FloorRepliesScreen(
          controller: widget.controller,
          contentRef: _item.ref,
          comment: comment,
          originalPosterId: _item.author.id,
          onCommentChanged: _rememberCommentLike,
          commentLikeUpdates: _commentLikeUpdates,
          pendingCommentLikes: _pendingCommentLikes,
          onCommentLikeStatusChanged: _commentLikeStatusChanged,
          drafts: _drafts,
          readingPreferences: _readingPreferences,
        ),
      ),
    );
  }

  void _rememberCommentLike(FeedComment comment) {
    if (!mounted) return;
    setState(() => _commentLikeUpdates[comment.ref.id] = comment);
  }

  void _commentLikeStatusChanged(Object? error) {
    if (!mounted) return;
    setState(() {});
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _likeComment(FeedComment comment) async {
    if (!_pendingCommentLikes.add(comment.ref.id)) return;
    final value = comment.liked != true;
    setState(() {});
    try {
      await widget.controller.commentLike(_item.ref, comment.ref, value);
      _rememberCommentLike(_confirmedCommentLike(comment, value));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      _pendingCommentLikes.remove(comment.ref.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _comment() async {
    await _composeAndSend();
  }

  Future<void> _reply(FeedComment comment) async {
    await _composeAndSend(target: comment);
  }

  Future<void> _composeAndSend({FeedComment? target}) async {
    if (_working) return;
    final capability = target == null
        ? SourceCapability.comment
        : SourceCapability.reply;
    final handoff = !widget.controller.supports(_item.ref.source, capability);
    setState(() => _working = true);
    try {
      final sent = await showCommentComposer(
        context,
        title: target == null ? '发表评论' : '回复 ${target.author.name}',
        hint: '友善交流，理性表达',
        replyPreview: target == null
            ? ''
            : '${target.floor > 0 ? '${target.floor}楼 · ' : ''}${target.author.name}：${target.body}',
        draftKey: CommentDraftStore.draftKey(_item.ref, target: target?.ref),
        drafts: _drafts,
        externalHandoff: handoff,
        onSend: (body) => handoff
            ? Clipboard.setData(ClipboardData(text: body))
            : target == null
            ? widget.controller.comment(_item.ref, body)
            : widget.controller.reply(_item.ref, target.ref, body),
      );
      if (!mounted || !sent) return;
      if (handoff) {
        _showMessage('正文已复制，草稿保留；请在官方网页核对回复对象后手动发送');
        _openTiebaInteraction();
      } else {
        _showMessage(target == null ? '评论已发送' : '回复已发送');
        await _load();
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    required String success,
    bool showSuccess = true,
  }) async {
    if (!mounted || _working) return;
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
    final comments = _comments
        .map((comment) => _withCommentLikeUpdates(comment, _commentLikeUpdates))
        .toList();
    final tiebaThread = _item.ref.source == SourceId.tieba;
    return Scaffold(
      appBar: AppBar(
        title: Text(_item.ref.source.label),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: '更多操作',
            enabled: !_working,
            onSelected: (String action) {
              switch (action) {
                case 'readLater':
                  unawaited(_toggleReadLater());
                  break;
                case 'copyLink':
                  unawaited(_copyContent(link: true));
                  break;
                case 'copyText':
                  unawaited(_copyContent(link: false));
                  break;
                case 'share':
                  unawaited(_shareContent());
                  break;
                case 'readingSettings':
                  unawaited(_showReadingPreferences());
                  break;
                case 'completed':
                  unawaited(_toggleCompleted());
                  break;
                case 'jumpPage':
                  unawaited(_choosePage());
                  break;
                case 'top':
                  if (_scrollController.hasClients) {
                    unawaited(
                      _scrollController.animateTo(
                        0,
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOut,
                      ),
                    );
                  }
                  break;
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
                value: 'readLater',
                enabled: !_readLaterWorking && _item.ref.id.isNotEmpty,
                checked: _readLater ?? false,
                child: Text(
                  _readLaterWorking
                      ? _readLater == null
                            ? '正在读取稍后阅读…'
                            : '正在更新稍后阅读…'
                      : _readLater == null
                      ? '重试读取稍后阅读状态'
                      : _readLater!
                      ? '移出稍后阅读'
                      : '加入稍后阅读',
                ),
              ),
              PopupMenuItem<String>(
                value: 'copyLink',
                enabled: contentLink(_item.ref) != null,
                child: const Text('复制帖子链接'),
              ),
              PopupMenuItem<String>(
                value: 'copyText',
                enabled: contentText(_item, body: _detail?.body).isNotEmpty,
                child: const Text('复制正文'),
              ),
              PopupMenuItem<String>(
                value: 'share',
                enabled: contentLink(_item.ref) != null,
                child: const Text('分享帖子链接'),
              ),
              const PopupMenuItem<String>(
                value: 'readingSettings',
                child: Text('字号与行距'),
              ),
              CheckedPopupMenuItem<String>(
                value: 'completed',
                checked: _completed,
                child: Text(_completed ? '标记未读' : '标记已读'),
              ),
              const PopupMenuItem<String>(value: 'top', child: Text('返回顶部')),
              if (tiebaThread) ...<PopupMenuEntry<String>>[
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: 'jumpPage',
                  enabled: !_loading,
                  child: Text(
                    _totalPages > 0
                        ? '跳转页码（$_currentPage/$_totalPages）'
                        : '跳转页码（第 $_currentPage 页）',
                  ),
                ),
                CheckedPopupMenuItem<String>(
                  value: 'reverse',
                  enabled: !_loading,
                  checked: _reverse,
                  child: const Text('倒序浏览'),
                ),
                CheckedPopupMenuItem<String>(
                  value: 'onlyOriginalPoster',
                  enabled: !_loading,
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
              if (_error != null)
                SliverToBoxAdapter(
                  child: _InlineLoadFailure(
                    message: '刷新失败：$_error',
                    onRetry: _loading ? null : _load,
                  ),
                ),
              if (_item.media.isNotEmpty)
                SliverToBoxAdapter(
                  child: _MediaCarousel(
                    item: _item,
                    onOpenImage: (MediaItem media) =>
                        _openImage(_item.ref.source, media),
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
                  canOpenProfile:
                      widget.controller.supportsProfile(
                        _item.author.ref.source,
                      ) &&
                      _item.author.ref.id.isNotEmpty,
                  onTopicTap: _openTopic,
                  readingPreferences: _readingPreferences,
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
                      if (tiebaThread)
                        TextButton(
                          onPressed: _loading ? null : _choosePage,
                          child: Text(
                            _totalPages > 0
                                ? '$_currentPage/$_totalPages 页'
                                : '第 $_currentPage 页',
                          ),
                        ),
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
                    return KeyedSubtree(
                      key: comment.ref.id.isEmpty
                          ? null
                          : _commentKeys.putIfAbsent(
                              comment.ref.id,
                              () => GlobalKey(),
                            ),
                      child: _CommentTile(
                        comment: comment,
                        originalPosterId: _item.author.id,
                        density: widget.controller.density,
                        canReply: _canReply && !_working,
                        canLike: _canLikeComment,
                        likeWorking: _pendingCommentLikes.contains(
                          comment.ref.id,
                        ),
                        onLike: () => _likeComment(comment),
                        onReply: () => _reply(comment),
                        onOpenImage: (MediaItem media) => _openImage(
                          comment.ref.source,
                          media,
                          items: comment.media,
                        ),
                        readingPreferences: _readingPreferences,
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
                      ),
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
              else if (_paginationError != null)
                SliverToBoxAdapter(
                  child: _InlineLoadFailure(
                    message: '加载更多回复失败：$_paginationError',
                    onRetry: _loading ? null : _loadMore,
                  ),
                )
              else if (_hasMore)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
                    child: OutlinedButton(
                      onPressed: _loading ? null : _loadMore,
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
        onOfficialInteraction: tiebaThread ? _openTiebaInteraction : null,
      ),
    );
  }
}

class _InlineLoadFailure extends StatelessWidget {
  const _InlineLoadFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ],
    ),
  );
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
              final imageUrl = item.fullImageUrl;
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
                        ProgressiveSourceNetworkImage(
                          media: item,
                          source: widget.item.ref.source,
                          quality: MediaImageQuality.detail,
                          fit: BoxFit.contain,
                          maxDimension: 2560,
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
    required this.onForumTap,
    required this.onAuthorTap,
    required this.onTopicTap,
    required this.readingPreferences,
    required this.canOpenProfile,
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
  final ReadingPreferences readingPreferences;
  final bool canOpenProfile;

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
                  onTap: canOpenProfile ? onAuthorTap : null,
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
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontSize: readingPreferences.fontSize,
                height: readingPreferences.lineHeight,
              ),
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

FeedComment _confirmedCommentLike(FeedComment comment, bool value) {
  // When the snapshot did not expose a state, its count cannot safely be
  // incremented: the source may have found it was already liked on the web.
  final delta = comment.liked == null || comment.liked == value
      ? 0
      : value
      ? 1
      : -1;
  return comment.copyWith(
    liked: value,
    likes: (comment.likes + delta).clamp(0, 1 << 31),
  );
}

FeedComment _withCommentLikeUpdates(
  FeedComment comment,
  Map<String, FeedComment> updates,
) {
  final update = updates[comment.ref.id];
  return comment.copyWith(
    liked: update?.liked,
    likes: update?.likes,
    replies: comment.replies
        .map((reply) => _withCommentLikeUpdates(reply, updates))
        .toList(),
  );
}

void _reconcileCommentLikes(
  Iterable<FeedComment> comments,
  Map<String, FeedComment> updates,
  Map<String, FeedComment> beforeRead,
) {
  for (final comment in comments) {
    // A new confirmed mutation must win over an older in-flight read. Later
    // refreshes with an explicit state may replace a pre-existing override.
    if (comment.liked != null &&
        identical(updates[comment.ref.id], beforeRead[comment.ref.id])) {
      updates.remove(comment.ref.id);
    }
    _reconcileCommentLikes(comment.replies, updates, beforeRead);
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.originalPosterId,
    required this.density,
    required this.canReply,
    required this.onReply,
    required this.onOpenImage,
    this.onOpenReplies,
    this.onTopicTap,
    this.canLike = false,
    this.likeWorking = false,
    this.onLike,
    this.readingPreferences = const ReadingPreferences(),
  });

  final FeedComment comment;
  final String originalPosterId;
  final FeedDensity density;
  final bool canReply;
  final VoidCallback onReply;
  final ValueChanged<MediaItem> onOpenImage;
  final VoidCallback? onOpenReplies;
  final ValueChanged<String>? onTopicTap;
  final bool canLike;
  final bool likeWorking;
  final VoidCallback? onLike;
  final ReadingPreferences readingPreferences;

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
                  style: TextStyle(
                    fontSize: readingPreferences.fontSize,
                    height: readingPreferences.lineHeight,
                  ),
                  onTopicTap: onTopicTap,
                ),
                if (comment.media.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  _CommentMediaStrip(
                    media: comment.media,
                    source: comment.ref.source,
                    onOpenImage: onOpenImage,
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  SocialRichText(
                                    text: reply.body,
                                    source: reply.ref.source,
                                    style: TextStyle(
                                      fontSize: readingPreferences.fontSize,
                                      height: readingPreferences.lineHeight,
                                    ),
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
                                  if (reply.media.isNotEmpty) ...<Widget>[
                                    const SizedBox(height: 6),
                                    _CommentMediaStrip(
                                      media: reply.media,
                                      source: reply.ref.source,
                                      onOpenImage: onOpenImage,
                                      dimension: 68,
                                    ),
                                  ],
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
                    if (canLike)
                      TextButton.icon(
                        key: ValueKey<String>('comment-like-${comment.ref.id}'),
                        onPressed: likeWorking ? null : onLike,
                        icon: likeWorking
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                comment.liked == true
                                    ? Icons.thumb_up_alt
                                    : Icons.thumb_up_alt_outlined,
                                size: 17,
                              ),
                        label: Text(
                          '${comment.likes}',
                          semanticsLabel:
                              '${comment.liked == true ? '取消评论点赞' : '点赞评论'}，${comment.likes}个赞',
                        ),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: comment.liked == true
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
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

class _CommentMediaStrip extends StatelessWidget {
  const _CommentMediaStrip({
    required this.media,
    required this.source,
    required this.onOpenImage,
    this.dimension = 92,
  });

  final List<MediaItem> media;
  final SourceId source;
  final ValueChanged<MediaItem> onOpenImage;
  final double dimension;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: dimension,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: media.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (BuildContext context, int index) {
        final item = media[index];
        return Semantics(
          button: true,
          label: '查看评论图片 ${index + 1}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: InkWell(
                onTap: () => onOpenImage(item),
                child: SizedBox.square(
                  dimension: dimension,
                  child: SourceNetworkImage(
                    url: item.previewImageUrl,
                    source: source,
                    fit: BoxFit.cover,
                    maxDimension: 512,
                    semanticLabel: '评论图片 ${index + 1}',
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Colors.transparent,
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _FloorRepliesScreen extends StatefulWidget {
  const _FloorRepliesScreen({
    required this.controller,
    required this.contentRef,
    required this.comment,
    required this.originalPosterId,
    required this.onCommentChanged,
    required this.commentLikeUpdates,
    required this.pendingCommentLikes,
    required this.onCommentLikeStatusChanged,
    required this.drafts,
    required this.readingPreferences,
  });

  final MixsocialController controller;
  final ContentRef contentRef;
  final FeedComment comment;
  final String originalPosterId;
  final ValueChanged<FeedComment> onCommentChanged;
  final Map<String, FeedComment> commentLikeUpdates;
  final Set<String> pendingCommentLikes;
  final ValueChanged<Object?> onCommentLikeStatusChanged;
  final CommentDraftStore drafts;
  final ReadingPreferences readingPreferences;

  @override
  State<_FloorRepliesScreen> createState() => _FloorRepliesScreenState();
}

class _FloorRepliesScreenState extends State<_FloorRepliesScreen> {
  final ScrollController _scrollController = ScrollController();
  Map<String, FeedComment> get _commentLikeUpdates => widget.commentLikeUpdates;
  Set<String> get _pendingCommentLikes => widget.pendingCommentLikes;
  late List<FeedComment> _replies = widget.controller.prepareComments(
    widget.comment.replies,
  );
  String _nextCursor = '';
  Object? _error;
  bool _errorOnLoadMore = false;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _working = false;
  int _requestGeneration = 0;

  bool get _canReply =>
      widget.contentRef.source == SourceId.tieba ||
      widget.controller.supports(
        widget.contentRef.source,
        SourceCapability.reply,
      );

  bool get _canLikeComment => widget.controller.supports(
    widget.contentRef.source,
    SourceCapability.commentLike,
  );

  Future<void> _likeComment(FeedComment comment) async {
    if (!_pendingCommentLikes.add(comment.ref.id)) return;
    final value = comment.liked != true;
    Object? failure;
    widget.onCommentLikeStatusChanged(null);
    setState(() {});
    try {
      await widget.controller.commentLike(
        widget.contentRef,
        comment.ref,
        value,
      );
      final updated = _confirmedCommentLike(comment, value);
      // The parent route remains mounted; synchronize its root and previews
      // even if this route was closed while the server response was pending.
      widget.onCommentChanged(updated);
      if (mounted) {
        setState(() => _commentLikeUpdates[comment.ref.id] = updated);
      }
    } catch (error) {
      failure = error;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      _pendingCommentLikes.remove(comment.ref.id);
      // A request outlives this route when the user goes back while waiting.
      // Rebuild the still-mounted parent after releasing the shared guard,
      // and deliver failures there if this route can no longer display them.
      widget.onCommentLikeStatusChanged(mounted ? null : failure);
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_error == null && _scrollController.position.extentAfter < 420) {
        unawaited(_loadMore());
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_requestGeneration;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _errorOnLoadMore = false;
    });
    try {
      final page = await widget.controller.floorReplies(widget.comment.ref);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _replies = _mergeReplies(page.comments);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore && page.nextCursor.isNotEmpty;
      });
    } catch (error) {
      if (mounted && generation == _requestGeneration) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  List<FeedComment> _mergeReplies(Iterable<FeedComment> incoming) {
    final result = List<FeedComment>.of(_replies);
    final indices = <String, int>{
      for (var index = 0; index < result.length; index++)
        if (result[index].ref.id.isNotEmpty) result[index].ref.id: index,
    };
    for (final comment in widget.controller.prepareComments(incoming)) {
      final index = indices[comment.ref.id];
      if (index == null) {
        if (comment.ref.id.isNotEmpty) indices[comment.ref.id] = result.length;
        result.add(comment);
      } else {
        result[index] = comment;
      }
    }
    return result;
  }

  Future<void> _loadMore() async {
    if (!mounted ||
        _loading ||
        _loadingMore ||
        !_hasMore ||
        _nextCursor.isEmpty) {
      return;
    }
    final generation = _requestGeneration;
    final cursor = _nextCursor;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await widget.controller.floorReplies(
        widget.comment.ref,
        cursor: cursor,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _replies = _mergeReplies(page.comments);
        _nextCursor = page.nextCursor;
        _hasMore =
            page.hasMore &&
            page.nextCursor.isNotEmpty &&
            page.nextCursor != cursor;
      });
    } catch (error) {
      if (mounted && generation == _requestGeneration) {
        setState(() {
          _error = error;
          _errorOnLoadMore = true;
        });
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _openImage(
    SourceId source,
    MediaItem media, {
    List<MediaItem> items = const <MediaItem>[],
  }) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            MediaPreviewScreen(source: source, media: media, mediaItems: items),
      ),
    );
  }

  Future<void> _reply(FeedComment target) async {
    if (_working) return;
    setState(() => _working = true);
    final handoff = !widget.controller.supports(
      widget.contentRef.source,
      SourceCapability.reply,
    );
    try {
      final sent = await showCommentComposer(
        context,
        title: '回复 ${target.author.name}',
        hint: '输入回复内容',
        replyPreview:
            '${target.floor > 0 ? '${target.floor}楼 · ' : ''}${target.author.name}：${target.body}',
        draftKey: CommentDraftStore.draftKey(
          widget.contentRef,
          target: target.ref,
        ),
        drafts: widget.drafts,
        externalHandoff: handoff,
        onSend: (body) => handoff
            ? Clipboard.setData(ClipboardData(text: body))
            : widget.controller.reply(widget.contentRef, target.ref, body),
      );
      if (!mounted || !sent) return;
      if (handoff) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正文已复制，草稿保留；请在官方网页核对回复对象后手动发送')),
        );
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => _TiebaInteractionScreen(
              controller: widget.controller,
              item: FeedItem(
                ref: widget.contentRef,
                title: '贴吧回复',
                author: target.author,
                stats: const ItemStats(),
              ),
            ),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('回复已发送')));
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString()),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = _withCommentLikeUpdates(widget.comment, _commentLikeUpdates);
    final replies = _replies
        .map((comment) => _withCommentLikeUpdates(comment, _commentLikeUpdates))
        .toList();
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
                comment: parent.copyWith(replies: const <FeedComment>[]),
                originalPosterId: widget.originalPosterId,
                density: widget.controller.density,
                readingPreferences: widget.readingPreferences,
                canReply: _canReply && !_working,
                canLike: _canLikeComment,
                likeWorking: _pendingCommentLikes.contains(parent.ref.id),
                onLike: () => _likeComment(parent),
                onReply: () => _reply(widget.comment),
                onOpenImage: (MediaItem media) => _openImage(
                  widget.comment.ref.source,
                  media,
                  items: widget.comment.media,
                ),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('读取回复失败：$_error'),
                      TextButton(
                        onPressed: _loading || _loadingMore
                            ? null
                            : _errorOnLoadMore
                            ? _loadMore
                            : _load,
                        child: const Text('重试加载回复'),
                      ),
                    ],
                  ),
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
                itemCount: replies.length,
                itemBuilder: (BuildContext context, int index) => _CommentTile(
                  comment: replies[index],
                  originalPosterId: widget.originalPosterId,
                  density: widget.controller.density,
                  readingPreferences: widget.readingPreferences,
                  canReply: _canReply && !_working,
                  canLike: _canLikeComment,
                  likeWorking: _pendingCommentLikes.contains(
                    replies[index].ref.id,
                  ),
                  onLike: () => _likeComment(replies[index]),
                  onReply: () => _reply(_replies[index]),
                  onOpenImage: (MediaItem media) => _openImage(
                    _replies[index].ref.source,
                    media,
                    items: _replies[index].media,
                  ),
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
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      SizedBox(width: 12),
                      Text('正在加载楼中楼回复…'),
                    ],
                  ),
                ),
              )
            else if (_hasMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton(
                    onPressed: _loading ? null : _loadMore,
                    child: const Text('加载更多楼中楼回复'),
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
    this.onOfficialInteraction,
  });

  final FeedItem item;
  final bool working;
  final bool canLike;
  final bool canFavorite;
  final bool canComment;
  final VoidCallback onLike;
  final VoidCallback onFavorite;
  final VoidCallback onComment;
  final VoidCallback? onOfficialInteraction;

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
                  label: !canLike && onOfficialInteraction != null
                      ? '网页点赞'
                      : compactCount(item.stats.likes),
                  selected: item.liked,
                  tooltip: !canLike && onOfficialInteraction != null
                      ? '在贴吧官方页面点赞'
                      : '点赞',
                  onPressed: !working
                      ? canLike
                            ? onLike
                            : onOfficialInteraction
                      : null,
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
                  label: !canComment && onOfficialInteraction != null
                      ? '网页评论'
                      : '评论',
                  tooltip: !canComment && onOfficialInteraction != null
                      ? '在贴吧官方页面发表评论或回复'
                      : '评论',
                  onPressed: !working
                      ? canComment
                            ? onComment
                            : onOfficialInteraction
                      : null,
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
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Theme.of(context).colorScheme.primary : null;
    return Tooltip(
      message: tooltip ?? '',
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: color),
        label: Text(label, maxLines: 1, style: TextStyle(color: color)),
      ),
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

class _TiebaInteractionScreen extends StatefulWidget {
  const _TiebaInteractionScreen({required this.controller, required this.item});

  final MixsocialController controller;
  final FeedItem item;

  @override
  State<_TiebaInteractionScreen> createState() =>
      _TiebaInteractionScreenState();
}

class _TiebaInteractionScreenState extends State<_TiebaInteractionScreen> {
  WebViewController? _webController;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _webController = null;
        _error = null;
      });
    }
    try {
      final controller = await widget.controller.tieba.interactionController(
        widget.item.ref,
      );
      if (mounted) setState(() => _webController = controller);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _webController;
    return Scaffold(
      appBar: AppBar(
        title: const Text('贴吧官方页面互动'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新网页',
            onPressed: controller?.reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          MaterialBanner(
            content: const Text('点赞、发表评论和回复由贴吧官方页面完成；应用内收藏仍保存在本机。'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回阅读'),
              ),
            ],
          ),
          Expanded(
            child: _error != null
                ? AppStateView(
                    icon: Icons.public_off_rounded,
                    title: '贴吧页面打开失败',
                    message: _error.toString(),
                    actionLabel: '重试',
                    onAction: _load,
                  )
                : controller == null
                ? const Center(child: CircularProgressIndicator())
                : WebViewWidget(
                    key: const Key('tieba-interaction-webview'),
                    controller: controller,
                  ),
          ),
        ],
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
