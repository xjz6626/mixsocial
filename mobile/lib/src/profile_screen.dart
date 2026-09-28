import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'detail_screen.dart';
import 'feed_widgets.dart';
import 'models.dart';
import 'network_media.dart';
import 'official_page_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.controller,
    required this.author,
    this.isOwnProfile = false,
  });

  final MixsocialController controller;
  final Author author;
  final bool isOwnProfile;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final ScrollController _scrollController = ScrollController();
  ProfileSection _section = ProfileSection.notes;
  ProfilePage? _profile;
  List<FeedItem> _items = const <FeedItem>[];
  String _nextCursor = '';
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _working = false;
  Object? _error;
  Object? _paginationError;
  int _requestGeneration = 0;
  late bool _following = widget.controller.isFollowing(
    widget.author.ref,
    fallback: widget.author.following,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncFollowing);
    _scrollController.addListener(_loadMoreNearEnd);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFollowing);
    _scrollController.dispose();
    super.dispose();
  }

  void _syncFollowing() {
    final value = widget.controller.isFollowing(
      widget.author.ref,
      fallback: widget.author.following,
      observed: _profile?.following,
    );
    if (mounted && value != _following) {
      setState(() => _following = value);
    }
  }

  void _loadMoreNearEnd() {
    if (_error == null &&
        _paginationError == null &&
        _scrollController.hasClients &&
        _scrollController.position.extentAfter < 520) {
      unawaited(_loadMore());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_requestGeneration;
    final section = _section;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _paginationError = null;
      _items = const <FeedItem>[];
      _nextCursor = '';
      _hasMore = false;
    });
    try {
      final page = await widget.controller.profile(
        widget.author.ref,
        section: section,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _profile = page;
        _items = widget.controller.prepareItems(page.items);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore && page.nextCursor.isNotEmpty;
        _following = widget.controller.isFollowing(
          widget.author.ref,
          fallback: widget.author.following,
          observed: page.following,
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
    final section = _section;
    setState(() {
      _loadingMore = true;
      _paginationError = null;
    });
    try {
      final page = await widget.controller.profile(
        widget.author.ref,
        section: section,
        cursor: cursor,
      );
      if (!mounted || generation != _requestGeneration) return;
      final seen = _items.map((FeedItem item) => item.key).toSet();
      final additions = widget.controller
          .prepareItems(page.items)
          .where((FeedItem item) => seen.add(item.key))
          .toList();
      setState(() {
        _profile = page;
        _items = <FeedItem>[..._items, ...additions];
        _nextCursor = page.nextCursor;
        _hasMore =
            page.hasMore &&
            additions.isNotEmpty &&
            page.nextCursor.isNotEmpty &&
            (page.nextCursor != cursor || cursor == 'more');
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

  Future<void> _selectSection(ProfileSection section) async {
    if (_section == section || _loading) return;
    setState(() => _section = section);
    // Reset cursors before jumping, since the scroll listener can otherwise
    // start a request for the new section using the previous section's cursor.
    final loading = _load();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await loading;
  }

  Future<void> _follow() async {
    if (_working) return;
    final value = !_following;
    setState(() => _working = true);
    try {
      final warning = await widget.controller.follow(widget.author.ref, value);
      if (mounted) {
        setState(() => _following = value);
        _message(warning ?? (value ? '已关注' : '已取消关注'));
      }
    } catch (error) {
      if (mounted) _message(error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _open(FeedItem item) async {
    await widget.controller.recordHistory(item);
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            DetailScreen(controller: widget.controller, initialItem: item),
      ),
    );
  }

  void _openOfficialProfile() {
    final ref = _profile?.ref ?? widget.author.ref;
    final uri = Uri.tryParse(ref.url);
    if (ref.source != SourceId.tieba || uri == null || uri.host != 'tieba.baidu.com' || uri.path != '/home/main' || uri.userInfo.isNotEmpty) {
      _message('当前资料没有可确认的官方主页链接，请稍后重试', error: true);
      return;
    }
    Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => OfficialPageScreen(
      source: SourceId.tieba, title: '贴吧官方个人主页',
      load: () => widget.controller.tieba.interactionController(ContentRef(source: SourceId.tieba, id: ref.id, url: ref.url)),
    )));
  }

  void _message(String value, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(title: Text(profile?.name ?? widget.author.name), actions: <Widget>[
        if (widget.author.ref.source == SourceId.tieba) IconButton(tooltip: '打开官方主页', onPressed: _openOfficialProfile, icon: const Icon(Icons.language)),
      ]),
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
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: _ProfileHeader(
                    author: widget.author,
                    profile: profile,
                    following: _following,
                    working: _working,
                    onFollow:
                        !widget.isOwnProfile &&
                            widget.controller.supports(
                              widget.author.ref.source,
                              SourceCapability.follow,
                            )
                        ? _follow
                        : null,
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: widget.author.ref.source == SourceId.tieba
                      ? const Text('公开帖子动态（主题与回复所在帖子）')
                      : SegmentedButton<ProfileSection>(
                      segments: ProfileSection.values
                          .map(
                            (ProfileSection value) =>
                                ButtonSegment<ProfileSection>(
                                  value: value,
                                  label: Text(value.label),
                                ),
                          )
                          .toList(),
                      selected: <ProfileSection>{_section},
                      showSelectedIcon: false,
                      onSelectionChanged: (Set<ProfileSection> values) =>
                          unawaited(_selectSection(values.single)),
                    ),
                  ),
                ),
              ),
            ),
            if (_error != null)
              SliverToBoxAdapter(
                child: AppStateView(
                  icon: Icons.person_off_outlined,
                  iconColor: Theme.of(context).colorScheme.error,
                  title: '主页加载失败',
                  message: _error.toString(),
                  actionLabel: '重新加载',
                  onAction: _load,
                  compact: true,
                ),
              )
            else if (!_loading && _items.isEmpty)
              SliverToBoxAdapter(
                child: AppStateView(
                  icon: Icons.article_outlined,
                  title: _section == ProfileSection.notes
                      ? '还没有公开笔记'
                      : '该分类没有公开内容',
                  message: '切换到其他分类看看，或者稍后下拉刷新。',
                  compact: true,
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                sliver: SliverList.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (BuildContext context, int index) {
                    final item = _items[index];
                    return Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 920),
                        child: _ProfileNoteCard(
                          item: item,
                          onTap: () => unawaited(_open(item)),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (_paginationError != null)
              SliverToBoxAdapter(
                child: AppStateView(
                  icon: Icons.cloud_off_outlined,
                  title: '加载更多失败',
                  message: _paginationError.toString(),
                  actionLabel: '重试加载更多',
                  onAction: _loadMore,
                  compact: true,
                ),
              )
            else if (_hasMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: OutlinedButton(
                    onPressed: _loadMore,
                    child: const Text('加载更多'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.author,
    required this.profile,
    required this.following,
    required this.working,
    required this.onFollow,
  });

  final Author author;
  final ProfilePage? profile;
  final bool following;
  final bool working;
  final VoidCallback? onFollow;

  @override
  Widget build(BuildContext context) {
    final value = profile;
    final displayAuthor = author.copyWith(
      name: value?.name ?? author.name,
      avatar: value?.avatar.isNotEmpty == true ? value!.avatar : null,
      avatarUrls: <String>[
        if (value != null) ...value.avatarUrls,
        if (author.avatar.isNotEmpty) author.avatar,
        ...author.avatarUrls,
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              AuthorAvatar(author: displayAuthor, radius: 34),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      displayAuthor.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (value?.redId.isNotEmpty == true)
                      Text('小红书号：${value!.redId}'),
                    if (value?.location.isNotEmpty == true)
                      Text('IP 属地：${value!.location}'),
                  ],
                ),
              ),
              if (onFollow != null)
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
          if (value?.description.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 14),
            Text(value!.description),
          ],
          if (value?.stats.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 14),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              children: value!.stats
                  .map(
                    (ProfileStat stat) => Text(
                      '${stat.count} ${stat.name}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProfileNoteCard extends StatelessWidget {
  const _ProfileNoteCard({required this.item, required this.onTap});

  final FeedItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = item.media.isEmpty ? '' : item.media.first.displayUrl;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 116,
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 116,
                child: cover.isEmpty
                    ? ColoredBox(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: Icon(
                          item.media.any(
                                (MediaItem media) => media.kind == 'video',
                              )
                              ? Icons.play_circle_outline
                              : Icons.image_outlined,
                        ),
                      )
                    : SourceNetworkImage(
                        url: cover,
                        source: item.ref.source,
                        fit: BoxFit.cover,
                        maxDimension: 480,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title.isEmpty ? item.summary : item.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const Spacer(),
                      Row(
                        children: <Widget>[
                          CompactStat(
                            icon: Icons.favorite_border,
                            value: item.stats.likes,
                          ),
                          const SizedBox(width: 14),
                          CompactStat(
                            icon: Icons.chat_bubble_outline,
                            value: item.stats.comments,
                          ),
                          if (item.media.any(
                            (MediaItem media) => media.kind == 'video',
                          )) ...<Widget>[
                            const Spacer(),
                            const Icon(Icons.play_circle_outline, size: 18),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
