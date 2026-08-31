import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'detail_screen.dart';
import 'feed_widgets.dart';
import 'models.dart';

class ForumHubScreen extends StatefulWidget {
  const ForumHubScreen({super.key, required this.controller});

  final MixsocialController controller;

  @override
  State<ForumHubScreen> createState() => _ForumHubScreenState();
}

class _ForumHubScreenState extends State<ForumHubScreen> {
  final TextEditingController _forumController = TextEditingController();
  List<String> _following = const <String>[];
  List<String> _recent = const <String>[];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _forumController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final recent = await widget.controller.recentForums();
    List<String> following = const <String>[];
    Object? error;
    try {
      following = await widget.controller.followingForums();
    } catch (failure) {
      error = failure;
    }
    if (!mounted) return;
    setState(() {
      _recent = recent;
      _following = following;
      _error = error;
      _loading = false;
    });
  }

  Future<void> _openForum(String value) async {
    final forum = value.trim().replaceFirst(RegExp(r'吧$'), '');
    if (forum.isEmpty) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            ForumScreen(controller: widget.controller, forum: forum),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('贴吧目录')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    TextField(
                      key: const Key('forum-name-input'),
                      controller: _forumController,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _openForum,
                      decoration: InputDecoration(
                        hintText: '输入吧名，例如：golang',
                        prefixIcon: const Icon(Icons.forum_outlined),
                        suffixIcon: IconButton(
                          tooltip: '进入贴吧',
                          onPressed: () => _openForum(_forumController.text),
                          icon: const Icon(Icons.arrow_forward),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (_loading) ...<Widget>[
                      const SizedBox(height: 14),
                      const LinearProgressIndicator(minHeight: 2),
                    ],
                    if (_recent.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 22),
                      Text(
                        '最近访问',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _recent
                            .map(
                              (String forum) => ActionChip(
                                avatar: const Icon(Icons.history, size: 17),
                                label: Text('$forum吧'),
                                onPressed: () => _openForum(forum),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                    const SizedBox(height: 22),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '已关注的吧',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text('${_following.length}'),
                      ],
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 10),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            '登录贴吧后可读取关注吧列表。\n$_error',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ] else if (!_loading && _following.isEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      const Text('暂无已关注贴吧'),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList.builder(
                itemCount: _following.length,
                itemBuilder: (BuildContext context, int index) {
                  final forum = _following[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      child: Text(forum.characters.first.toUpperCase()),
                    ),
                    title: Text('$forum吧'),
                    subtitle: widget.controller.isForumBlocked(forum)
                        ? const Text('已在本地屏蔽')
                        : null,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openForum(forum),
                  );
                },
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }
}

class ForumScreen extends StatefulWidget {
  const ForumScreen({super.key, required this.controller, required this.forum});

  final MixsocialController controller;
  final String forum;

  @override
  State<ForumScreen> createState() => _ForumScreenState();
}

class _ForumScreenState extends State<ForumScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  List<FeedItem> _items = const <FeedItem>[];
  Object? _error;
  String _query = '';
  String _nextCursor = '';
  int _sortType = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.extentAfter < 520) unawaited(_loadMore());
    });
    unawaited(widget.controller.recordForumVisit(widget.forum));
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
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
      final page = await widget.controller.forum(
        widget.forum,
        sortType: _sortType,
        query: _query,
      );
      if (!mounted) return;
      setState(() {
        _items = widget.controller.prepareItems(page.items);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (failure) {
      if (mounted) setState(() => _error = failure);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _nextCursor.isEmpty) return;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await widget.controller.forum(
        widget.forum,
        cursor: _nextCursor,
        sortType: _sortType,
        query: _query,
      );
      if (!mounted) return;
      final seen = _items.map((FeedItem item) => item.key).toSet();
      setState(() {
        _items = <FeedItem>[
          ..._items,
          ...widget.controller.prepareItems(
            page.items.where((FeedItem item) => seen.add(item.key)),
          ),
        ];
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (failure) {
      if (mounted) setState(() => _error = failure);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _submitSearch(String value) async {
    _query = value.trim();
    await _load();
  }

  Future<void> _blockForum() async {
    final blocked = widget.controller.isForumBlocked(widget.forum);
    await widget.controller.setForumBlocked(widget.forum, !blocked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(blocked ? '已解除屏蔽' : '已屏蔽 ${widget.forum}吧')),
    );
    if (!blocked) Navigator.pop(context);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.forum}吧'),
        actions: <Widget>[
          IconButton(
            tooltip: '吧内搜索',
            onPressed: () => setState(() => _searching = !_searching),
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton<String>(
            onSelected: (String value) {
              if (value == 'block') unawaited(_blockForum());
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'block',
                child: Text(
                  widget.controller.isForumBlocked(widget.forum)
                      ? '解除屏蔽此吧'
                      : '屏蔽此吧',
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: SearchBar(
                key: const Key('forum-search-field'),
                controller: _searchController,
                hintText: '在 ${widget.forum}吧 内搜索',
                leading: const Icon(Icons.search),
                trailing: <Widget>[
                  if (_query.isNotEmpty)
                    IconButton(
                      onPressed: () {
                        _searchController.clear();
                        unawaited(_submitSearch(''));
                      },
                      icon: const Icon(Icons.close),
                    ),
                ],
                textInputAction: TextInputAction.search,
                onSubmitted: _submitSearch,
              ),
            ),
          if (_query.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: SegmentedButton<int>(
                segments: const <ButtonSegment<int>>[
                  ButtonSegment<int>(value: 0, label: Text('最新回复')),
                  ButtonSegment<int>(value: 1, label: Text('最新发布')),
                ],
                selected: <int>{_sortType},
                onSelectionChanged: (Set<int> values) {
                  _sortType = values.single;
                  unawaited(_load());
                },
              ),
            ),
          if (_loading && _items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading && _items.isEmpty
                  ? const CustomScrollView(
                      physics: AlwaysScrollableScrollPhysics(),
                      slivers: <Widget>[
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: AppLoadingView(
                            title: '正在加载贴吧主题',
                            message: '正在读取最新帖子',
                          ),
                        ),
                      ],
                    )
                  : _error != null && _items.isEmpty
                  ? CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: <Widget>[
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: AppStateView(
                            icon: Icons.cloud_off_outlined,
                            iconColor: Theme.of(context).colorScheme.error,
                            title: '贴吧内容加载失败',
                            message: _error.toString(),
                            actionLabel: '重新加载',
                            onAction: _load,
                          ),
                        ),
                      ],
                    )
                  : _items.isEmpty
                  ? CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: <Widget>[
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: AppStateView(
                            icon: _query.isEmpty
                                ? Icons.forum_outlined
                                : Icons.search_off_rounded,
                            title: _query.isEmpty ? '这个吧暂时没有主题' : '没有找到相关主题',
                            message: _query.isEmpty
                                ? '稍后下拉刷新，或者切换排序方式再看看。'
                                : '尝试缩短关键词或清空吧内搜索。',
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
                      itemCount: _items.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (BuildContext context, int index) {
                        if (index == _items.length) {
                          if (_loadingMore) {
                            return const Padding(
                              padding: EdgeInsets.all(18),
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          }
                          if (_error != null) {
                            return Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 920,
                                ),
                                child: Card(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.errorContainer,
                                  child: ListTile(
                                    leading: const Icon(Icons.error_outline),
                                    title: const Text('加载更多失败'),
                                    subtitle: Text(
                                      _error.toString(),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: IconButton(
                                      tooltip: '重试',
                                      onPressed: _loadMore,
                                      icon: const Icon(Icons.refresh),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }
                          return Padding(
                            padding: const EdgeInsets.all(18),
                            child: const Center(child: Text('已经到底了')),
                          );
                        }
                        return Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 920),
                            child: _ForumFeedCard(
                              item: _items[index],
                              density: widget.controller.density,
                              onTap: () => _open(_items[index]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ForumFeedCard extends StatelessWidget {
  const _ForumFeedCard({
    required this.item,
    required this.density,
    required this.onTap,
  });

  final FeedItem item;
  final FeedDensity density;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(switch (density) {
            FeedDensity.compact => 9,
            FeedDensity.standard => 13,
            FeedDensity.comfortable => 17,
          }),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.title.isEmpty ? item.summary : item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.summary.isNotEmpty &&
                        item.summary != item.title) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        item.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        AuthorAvatar(author: item.author, radius: 10),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.author.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        CompactStat(
                          icon: Icons.chat_bubble_outline,
                          value: item.stats.comments,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (item.media.isNotEmpty) ...<Widget>[
                const SizedBox(width: 10),
                SizedBox(
                  width: 94,
                  child: FeedMediaPreview(
                    item: item,
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
