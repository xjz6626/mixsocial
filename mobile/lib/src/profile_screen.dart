import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'detail_screen.dart';
import 'feed_widgets.dart';
import 'models.dart';
import 'network_media.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.controller,
    required this.author,
  });

  final MixsocialController controller;
  final Author author;

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
  late bool _following =
      widget.controller.isFollowing(widget.author.ref) ||
      widget.author.following;

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
    setState(() {
      _loading = true;
      _error = null;
      _items = const <FeedItem>[];
      _nextCursor = '';
      _hasMore = false;
    });
    try {
      final page = await widget.controller.profile(
        widget.author.ref,
        section: _section,
      );
      if (!mounted) return;
      setState(() {
        _profile = page;
        _items = widget.controller.prepareItems(page.items);
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
      final page = await widget.controller.profile(
        widget.author.ref,
        section: _section,
        cursor: _nextCursor,
      );
      if (!mounted) return;
      final seen = _items.map((FeedItem item) => item.key).toSet();
      final additions = widget.controller
          .prepareItems(page.items)
          .where((FeedItem item) => seen.add(item.key))
          .toList();
      setState(() {
        _profile = page;
        _items = <FeedItem>[..._items, ...additions];
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore && additions.isNotEmpty;
      });
    } catch (error) {
      if (mounted) _message('加载更多笔记失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _selectSection(ProfileSection section) async {
    if (_section == section || _loading) return;
    setState(() => _section = section);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _load();
  }

  Future<void> _follow() async {
    if (_working) return;
    final value = !_following;
    setState(() => _working = true);
    try {
      await widget.controller.follow(widget.author.ref, value);
      if (mounted) {
        setState(() => _following = value);
        _message(value ? '已关注' : '已取消关注');
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
      appBar: AppBar(title: Text(profile?.name ?? widget.author.name)),
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
                    onFollow: _follow,
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
                    child: SegmentedButton<ProfileSection>(
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
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    final value = profile;
    final displayAuthor = author.copyWith(
      name: value?.name ?? author.name,
      avatar: value?.avatar.isNotEmpty == true ? value!.avatar : author.avatar,
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
