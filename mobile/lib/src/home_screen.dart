import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'detail_screen.dart';
import 'feed_widgets.dart';
import 'forum_screen.dart';
import 'login_screen.dart';
import 'models.dart';
import 'profile_screen.dart';
import 'xhs_web_source.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final MixsocialController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Map<SourceId, ScrollController> _scrollControllers =
      <SourceId, ScrollController>{};
  final ScrollController _searchScrollController = ScrollController();
  final TextEditingController _searchTextController = TextEditingController();
  Timer? _scrollSaveTimer;
  int _destination = 0;
  int _lastSearchNavigationId = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
    widget.controller.searchNavigationNotifier.addListener(
      _searchNavigationChanged,
    );
    _searchTextController.addListener(_searchInputChanged);
    _searchScrollController.addListener(
      () => _loadMoreNearEnd(_searchScrollController),
    );
    unawaited(_prepareScrollControllers());
  }

  Future<void> _prepareScrollControllers() async {
    final offsets = await Future.wait<double>(
      SourceId.values.map(widget.controller.settings.scrollOffsetFor),
    );
    if (!mounted) return;
    for (var index = 0; index < SourceId.values.length; index++) {
      final source = SourceId.values[index];
      final scrollController = ScrollController(
        initialScrollOffset: offsets[index],
      );
      scrollController.addListener(() {
        _scheduleScrollSave(source, scrollController);
        _loadMoreNearEnd(scrollController);
      });
      _scrollControllers[source] = scrollController;
    }
    setState(() {});
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
  }

  void _searchNavigationChanged() {
    final request = widget.controller.searchNavigationNotifier.value;
    if (request == null || request.id == _lastSearchNavigationId) return;
    _lastSearchNavigationId = request.id;
    unawaited(_navigateToSearch(request));
  }

  Future<void> _navigateToSearch(SearchNavigationRequest request) async {
    if (!mounted) return;
    Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
    setState(() => _destination = 1);
    _searchTextController.text = request.query;
    if (widget.controller.searchQuery.isNotEmpty) {
      await widget.controller.search('');
    }
    await _selectSource(request.source, preserveSearch: true);
    if (mounted) await _submitSearch(request.query);
  }

  void _searchInputChanged() {
    if (mounted && _destination == 1) setState(() {});
  }

  void _loadMoreNearEnd(ScrollController scrollController) {
    if (scrollController.hasClients &&
        scrollController.position.extentAfter < 640) {
      unawaited(widget.controller.loadMore());
    }
  }

  void _scheduleScrollSave(SourceId source, ScrollController scrollController) {
    _scrollSaveTimer?.cancel();
    _scrollSaveTimer = Timer(const Duration(milliseconds: 450), () {
      if (scrollController.hasClients) {
        unawaited(
          widget.controller.settings.setScrollOffset(
            source,
            scrollController.offset,
          ),
        );
      }
    });
  }

  Future<void> _selectSource(
    SourceId source, {
    bool preserveSearch = false,
  }) async {
    final previous = widget.controller.source;
    final previousScroll = preserveSearch ? null : _scrollControllers[previous];
    if (previousScroll?.hasClients ?? false) {
      await widget.controller.settings.setScrollOffset(
        previous,
        previousScroll!.offset,
      );
    }
    await widget.controller.selectSource(
      source,
      preserveSearch: preserveSearch,
    );
    if (preserveSearch && _searchScrollController.hasClients) {
      _searchScrollController.jumpTo(0);
    }
  }

  Future<void> _selectChannel(FeedChannel channel) async {
    final scrollController = _scrollControllers[widget.controller.source];
    if (scrollController?.hasClients ?? false) scrollController!.jumpTo(0);
    await widget.controller.selectChannel(channel);
  }

  Future<void> _submitSearch(String value) async {
    if (_searchScrollController.hasClients) _searchScrollController.jumpTo(0);
    await widget.controller.search(value);
  }

  Future<void> _selectDestination(int value) async {
    if (_destination == value) {
      if (value == 0) {
        final scrollController = _scrollControllers[widget.controller.source];
        if (scrollController?.hasClients ?? false) {
          await scrollController!.animateTo(
            0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
          );
        }
        await widget.controller.refresh();
      }
      return;
    }
    final leavingSearch = _destination == 1 && value != 1;
    setState(() => _destination = value);
    if (leavingSearch) await widget.controller.restoreFeed();
  }

  void _openItem(FeedItem item) {
    unawaited(_openItemAsync(item));
  }

  Future<void> _openItemAsync(FeedItem item) async {
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

  void _openForum(String forum) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            ForumScreen(controller: widget.controller, forum: forum),
      ),
    );
  }

  void _openProfile(Author author) {
    if (author.ref.source != SourceId.xhs || author.ref.id.isEmpty) return;
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            ProfileScreen(controller: widget.controller, author: author),
      ),
    );
  }

  Future<void> _openXhsFilters() async {
    final filters = await showModalBottomSheet<XhsSearchFilters>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _XhsSearchFilterSheet(initial: widget.controller.xhsSearchFilters),
    );
    if (filters != null) {
      await widget.controller.setXhsSearchFilters(filters);
    }
  }

  Future<void> _blockForum(FeedItem item) async {
    final forum = item.forumName;
    if (forum.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('屏蔽 $forum吧？'),
        content: const Text('该吧的内容将从首页、搜索和本地列表中隐藏。'),
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
    if (confirmed == true) await widget.controller.setForumBlocked(forum, true);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    widget.controller.searchNavigationNotifier.removeListener(
      _searchNavigationChanged,
    );
    _scrollSaveTimer?.cancel();
    _searchScrollController.dispose();
    _searchTextController.dispose();
    for (final entry in _scrollControllers.entries) {
      if (entry.value.hasClients) {
        unawaited(
          widget.controller.settings.setScrollOffset(
            entry.key,
            entry.value.offset,
          ),
        );
      }
      entry.value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final feedReady = _scrollControllers.isNotEmpty;
    final width = MediaQuery.sizeOf(context).width;
    final navigationLayout = navigationLayoutForWidth(width);
    final useNavigationRail = navigationLayout != AppNavigationLayout.bottomBar;
    final extendNavigationRail =
        navigationLayout == AppNavigationLayout.extendedRail;
    final destinations = <Widget>[
      Column(
        children: <Widget>[
          _SourceSelector(
            selected: controller.source,
            onSelected: _selectSource,
          ),
          _ChannelSelector(
            selected: controller.channel,
            onSelected: _selectChannel,
          ),
          if (controller.loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: !feedReady
                ? const AppLoadingView(message: '正在恢复你的阅读位置')
                : _FeedBody(
                    controller: controller,
                    scrollController: _scrollControllers[controller.source]!,
                    onOpen: _openItem,
                    onAuthorTap: _openProfile,
                    onForumTap: _openForum,
                    onBlockForum: _blockForum,
                  ),
          ),
        ],
      ),
      _SearchPage(
        controller: controller,
        textController: _searchTextController,
        scrollController: _searchScrollController,
        onSearch: _submitSearch,
        onSourceSelected: (SourceId source) =>
            _selectSource(source, preserveSearch: true),
        onOpen: _openItem,
        onAuthorTap: _openProfile,
        onForumTap: _openForum,
        onBlockForum: _blockForum,
        onXhsFilters: _openXhsFilters,
      ),
      AccountScreen(controller: controller),
    ];
    final content = IndexedStack(index: _destination, children: destinations);
    return PopScope(
      canPop: _destination == 0,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _destination != 0) {
          unawaited(_selectDestination(0));
        }
      },
      child: Scaffold(
        appBar: _destination == 2
            ? null
            : AppBar(
                title: Text(_destination == 0 ? 'Mixsocial' : '搜索'),
                actions: _destination == 0
                    ? <Widget>[
                        IconButton(
                          tooltip: '贴吧目录',
                          onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  ForumHubScreen(controller: controller),
                            ),
                          ),
                          icon: const Icon(Icons.forum_outlined),
                        ),
                        IconButton(
                          tooltip: controller.layout == FeedLayout.masonry
                              ? '切换为列表'
                              : '切换为双列',
                          onPressed: controller.toggleLayout,
                          icon: Icon(
                            controller.layout == FeedLayout.masonry
                                ? Icons.view_agenda_outlined
                                : Icons.grid_view_outlined,
                          ),
                        ),
                      ]
                    : null,
              ),
        body: useNavigationRail
            ? Row(
                children: <Widget>[
                  SafeArea(
                    top: _destination == 2,
                    child: NavigationRail(
                      extended: extendNavigationRail,
                      labelType: extendNavigationRail
                          ? NavigationRailLabelType.none
                          : NavigationRailLabelType.all,
                      groupAlignment: -.82,
                      selectedIndex: _destination,
                      onDestinationSelected: (int value) =>
                          unawaited(_selectDestination(value)),
                      destinations: const <NavigationRailDestination>[
                        NavigationRailDestination(
                          icon: Icon(Icons.dynamic_feed_outlined),
                          selectedIcon: Icon(Icons.dynamic_feed),
                          label: Text('首页'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.search_outlined),
                          selectedIcon: Icon(Icons.search),
                          label: Text('搜索'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.person_outline),
                          selectedIcon: Icon(Icons.person),
                          label: Text('我的'),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(),
                  Expanded(child: content),
                ],
              )
            : content,
        bottomNavigationBar: useNavigationRail
            ? null
            : NavigationBar(
                selectedIndex: _destination,
                onDestinationSelected: (int value) =>
                    unawaited(_selectDestination(value)),
                destinations: const <NavigationDestination>[
                  NavigationDestination(
                    icon: Icon(Icons.dynamic_feed_outlined),
                    selectedIcon: Icon(Icons.dynamic_feed),
                    label: '首页',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.search_outlined),
                    selectedIcon: Icon(Icons.search),
                    label: '搜索',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: '我的',
                  ),
                ],
              ),
      ),
    );
  }
}

class _SearchPage extends StatelessWidget {
  const _SearchPage({
    required this.controller,
    required this.textController,
    required this.scrollController,
    required this.onSearch,
    required this.onSourceSelected,
    required this.onOpen,
    required this.onAuthorTap,
    required this.onForumTap,
    required this.onBlockForum,
    required this.onXhsFilters,
  });

  final MixsocialController controller;
  final TextEditingController textController;
  final ScrollController scrollController;
  final ValueChanged<String> onSearch;
  final ValueChanged<SourceId> onSourceSelected;
  final ValueChanged<FeedItem> onOpen;
  final ValueChanged<Author> onAuthorTap;
  final ValueChanged<String> onForumTap;
  final ValueChanged<FeedItem> onBlockForum;
  final VoidCallback onXhsFilters;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SearchBar(
            key: const Key('feed-search-field'),
            controller: textController,
            hintText: '搜索帖子、笔记或关键词',
            leading: const Icon(Icons.search),
            trailing: <Widget>[
              if (controller.source != SourceId.tieba)
                IconButton(
                  tooltip: controller.xhsSearchFilters.isDefault
                      ? '小红书搜索筛选'
                      : '小红书搜索筛选（已启用）',
                  onPressed: onXhsFilters,
                  icon: Badge(
                    isLabelVisible: !controller.xhsSearchFilters.isDefault,
                    child: const Icon(Icons.tune),
                  ),
                ),
              if (textController.text.isNotEmpty)
                IconButton(
                  tooltip: '清空',
                  onPressed: () {
                    textController.clear();
                    onSearch('');
                  },
                  icon: const Icon(Icons.close),
                ),
            ],
            textInputAction: TextInputAction.search,
            onSubmitted: onSearch,
          ),
        ),
        _SourceSelector(
          selected: controller.source,
          onSelected: onSourceSelected,
          compact: true,
        ),
        if (controller.loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: controller.searchQuery.isEmpty
              ? const _SearchPrompt()
              : _FeedBody(
                  controller: controller,
                  scrollController: scrollController,
                  storageKey: 'search-results',
                  onOpen: onOpen,
                  onAuthorTap: onAuthorTap,
                  onForumTap: onForumTap,
                  onBlockForum: onBlockForum,
                ),
        ),
      ],
    );
  }
}

class _XhsSearchFilterSheet extends StatefulWidget {
  const _XhsSearchFilterSheet({required this.initial});

  final XhsSearchFilters initial;

  @override
  State<_XhsSearchFilterSheet> createState() => _XhsSearchFilterSheetState();
}

class _XhsSearchFilterSheetState extends State<_XhsSearchFilterSheet> {
  late XhsSearchFilters _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('小红书搜索筛选', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                '筛选由 PC 网页端执行，会保留当前 WebView 登录态。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              _FilterDropdown(
                label: '排序依据',
                value: _value.sortBy,
                options: const <String>['综合', '最新', '最多点赞', '最多评论', '最多收藏'],
                onChanged: (String value) =>
                    setState(() => _value = _value.copyWith(sortBy: value)),
              ),
              _FilterDropdown(
                label: '笔记类型',
                value: _value.noteType,
                options: const <String>['不限', '视频', '图文'],
                onChanged: (String value) =>
                    setState(() => _value = _value.copyWith(noteType: value)),
              ),
              _FilterDropdown(
                label: '发布时间',
                value: _value.publishTime,
                options: const <String>['不限', '一天内', '一周内', '半年内'],
                onChanged: (String value) => setState(
                  () => _value = _value.copyWith(publishTime: value),
                ),
              ),
              _FilterDropdown(
                label: '搜索范围',
                value: _value.searchScope,
                options: const <String>['不限', '已看过', '未看过', '已关注'],
                onChanged: (String value) => setState(
                  () => _value = _value.copyWith(searchScope: value),
                ),
              ),
              _FilterDropdown(
                label: '位置距离',
                value: _value.location,
                options: const <String>['不限', '同城', '附近'],
                onChanged: (String value) =>
                    setState(() => _value = _value.copyWith(location: value)),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          setState(() => _value = const XhsSearchFilters()),
                      child: const Text('重置'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, _value),
                      child: const Text('应用'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: options
            .map(
              (String option) =>
                  DropdownMenuItem<String>(value: option, child: Text(option)),
            )
            .toList(),
        onChanged: (String? value) {
          if (value != null) onChanged(value);
        },
      ),
    );
  }
}

class _SearchPrompt extends StatelessWidget {
  const _SearchPrompt();

  @override
  Widget build(BuildContext context) {
    return const AppStateView(
      icon: Icons.manage_search_rounded,
      title: '搜索你真正想看的内容',
      message: '贴吧会搜索全站主题，小红书会搜索公开笔记。可先选择平台，再输入关键词。',
    );
  }
}

class _SourceSelector extends StatelessWidget {
  const _SourceSelector({
    required this.selected,
    required this.onSelected,
    this.compact = false,
  });

  final SourceId selected;
  final ValueChanged<SourceId> onSelected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, compact ? 4 : 6, 12, compact ? 6 : 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<SourceId>(
          key: const Key('source-selector'),
          segments: SourceId.values
              .map(
                (SourceId source) => ButtonSegment<SourceId>(
                  value: source,
                  label: Text(source.label),
                ),
              )
              .toList(),
          selected: <SourceId>{selected},
          showSelectedIcon: false,
          onSelectionChanged: (Set<SourceId> values) =>
              onSelected(values.single),
        ),
      ),
    );
  }
}

class _ChannelSelector extends StatelessWidget {
  const _ChannelSelector({required this.selected, required this.onSelected});

  final FeedChannel selected;
  final ValueChanged<FeedChannel> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Row(
        children: FeedChannel.values
            .map(
              (FeedChannel channel) => Expanded(
                child: InkWell(
                  key: Key('channel-${channel.id}'),
                  onTap: () => onSelected(channel),
                  child: SizedBox(
                    height: 44,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        Text(
                          channel.label,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: selected == channel
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                fontWeight: selected == channel
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                        ),
                        const SizedBox(height: 9),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: selected == channel ? 26 : 0,
                          height: 3,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _FeedBody extends StatelessWidget {
  const _FeedBody({
    required this.controller,
    required this.scrollController,
    required this.onOpen,
    required this.onAuthorTap,
    required this.onForumTap,
    required this.onBlockForum,
    this.storageKey,
  });

  final MixsocialController controller;
  final ScrollController scrollController;
  final ValueChanged<FeedItem> onOpen;
  final ValueChanged<Author> onAuthorTap;
  final ValueChanged<String> onForumTap;
  final ValueChanged<FeedItem> onBlockForum;
  final String? storageKey;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: CustomScrollView(
        key: PageStorageKey<String>(
          storageKey ?? 'feed-${controller.source.id}-${controller.channel.id}',
        ),
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          if (controller.error != null && controller.items.isNotEmpty)
            SliverToBoxAdapter(
              child: _ErrorNotice(
                message: controller.error!,
                onRetry: controller.refresh,
              ),
            ),
          if (controller.notices.isNotEmpty)
            SliverToBoxAdapter(child: _Notices(messages: controller.notices)),
          if (controller.items.isEmpty && controller.loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: AppLoadingView(),
            )
          else if (controller.items.isEmpty && controller.error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: AppStateView(
                icon: Icons.cloud_off_outlined,
                iconColor: Theme.of(context).colorScheme.error,
                title: '内容加载失败',
                message: controller.error!,
                actionLabel: '重新加载',
                onAction: controller.refresh,
              ),
            )
          else if (controller.items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: AppStateView(
                icon: controller.searchQuery.isEmpty
                    ? Icons.inbox_outlined
                    : Icons.search_off_rounded,
                title: controller.searchQuery.isEmpty ? '这里暂时没有内容' : '没有找到相关内容',
                message: controller.searchQuery.isEmpty
                    ? '换个内容源或频道看看，也可以下拉重新加载。'
                    : '试试更短的关键词，或者切换内容源后再次搜索。',
                actionLabel: '重新加载',
                onAction: controller.refresh,
              ),
            )
          else if (controller.layout == FeedLayout.masonry)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
              sliver: SliverLayoutBuilder(
                builder: (BuildContext context, SliverConstraints constraints) {
                  return SliverMasonryGrid.count(
                    crossAxisCount: feedColumnCountForWidth(
                      constraints.crossAxisExtent,
                    ),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childCount: controller.items.length,
                    itemBuilder: (BuildContext context, int index) =>
                        MasonryFeedCard(
                          item: controller.items[index],
                          onTap: () => onOpen(controller.items[index]),
                          density: controller.density,
                          onAuthorTap:
                              controller.items[index].ref.source == SourceId.xhs
                              ? () =>
                                    onAuthorTap(controller.items[index].author)
                              : null,
                          onForumTap: onForumTap,
                          onBlockForum: () =>
                              onBlockForum(controller.items[index]),
                        ),
                  );
                },
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (BuildContext context, int index) => Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: ListFeedCard(
                          item: controller.items[index],
                          onTap: () => onOpen(controller.items[index]),
                          density: controller.density,
                          onAuthorTap:
                              controller.items[index].ref.source == SourceId.xhs
                              ? () =>
                                    onAuthorTap(controller.items[index].author)
                              : null,
                          onForumTap: onForumTap,
                          onBlockForum: () =>
                              onBlockForum(controller.items[index]),
                        ),
                      ),
                    ),
                  ),
                  childCount: controller.items.length,
                ),
              ),
            ),
          if (controller.loadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 2, 16, 24),
                child: Center(
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              ),
            )
          else if (controller.paginationError != null)
            SliverToBoxAdapter(
              child: _ErrorNotice(
                message: controller.paginationError!,
                onRetry: controller.loadMore,
              ),
            )
          else if (controller.items.isNotEmpty && !controller.hasMore)
            const SliverToBoxAdapter(child: _EndOfFeed()),
        ],
      ),
    );
  }
}

class _EndOfFeed extends StatelessWidget {
  const _EndOfFeed();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
      child: Row(
        children: <Widget>[
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '已经到底了',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class MasonryFeedCard extends StatelessWidget {
  const MasonryFeedCard({
    super.key,
    required this.item,
    required this.onTap,
    this.density = FeedDensity.standard,
    this.onAuthorTap,
    this.onForumTap,
    this.onBlockForum,
  });

  final FeedItem item;
  final VoidCallback onTap;
  final FeedDensity density;
  final VoidCallback? onAuthorTap;
  final ValueChanged<String>? onForumTap;
  final VoidCallback? onBlockForum;

  @override
  Widget build(BuildContext context) {
    final title = item.title.isNotEmpty ? item.title : item.summary;
    return Card(
      key: Key('masonry-${item.ref.source.id}-${item.ref.id}'),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (item.media.isNotEmpty)
              FeedMediaPreview(item: item)
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                child: SourceBadge(source: item.ref.source),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                10,
                density == FeedDensity.compact ? 7 : 9,
                10,
                density == FeedDensity.comfortable ? 14 : 10,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title.isEmpty ? '无标题' : title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (item.forumName.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 5),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: InkWell(
                            onTap: onForumTap == null
                                ? null
                                : () => onForumTap!(item.forumName),
                            child: Text(
                              '${item.forumName}吧',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                            ),
                          ),
                        ),
                        if (onBlockForum != null)
                          SizedBox.square(
                            dimension: 28,
                            child: IconButton(
                              tooltip: '屏蔽此吧',
                              padding: EdgeInsets.zero,
                              onPressed: onBlockForum,
                              icon: const Icon(Icons.hide_source, size: 17),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 9),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: InkWell(
                          onTap: onAuthorTap,
                          child: Row(
                            children: <Widget>[
                              AuthorAvatar(author: item.author, radius: 10),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  item.author.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      CompactStat(
                        icon: Icons.favorite_border,
                        value: item.stats.likes,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ListFeedCard extends StatelessWidget {
  const ListFeedCard({
    super.key,
    required this.item,
    required this.onTap,
    this.density = FeedDensity.standard,
    this.onAuthorTap,
    this.onForumTap,
    this.onBlockForum,
  });

  final FeedItem item;
  final VoidCallback onTap;
  final FeedDensity density;
  final VoidCallback? onAuthorTap;
  final ValueChanged<String>? onForumTap;
  final VoidCallback? onBlockForum;

  @override
  Widget build(BuildContext context) {
    final title = item.title.isNotEmpty ? item.title : item.summary;
    final hasMedia = item.media.isNotEmpty;
    return Card(
      key: Key('list-${item.ref.source.id}-${item.ref.id}'),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            14,
            density == FeedDensity.compact ? 8 : 12,
            14,
            density == FeedDensity.comfortable ? 16 : 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  SourceBadge(source: item.ref.source),
                  if (item.tags.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: item.forumName.isEmpty || onForumTap == null
                            ? null
                            : () => onForumTap!(item.forumName),
                        child: Text(
                          item.tags.first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: item.forumName.isEmpty
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant
                                    : Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ),
                    ),
                  ] else
                    const Spacer(),
                  if (item.publishedAt != null)
                    Text(
                      _relativeTime(item.publishedAt!),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  if (item.forumName.isNotEmpty && onBlockForum != null)
                    SizedBox.square(
                      dimension: 32,
                      child: IconButton(
                        tooltip: '屏蔽此吧',
                        padding: EdgeInsets.zero,
                        onPressed: onBlockForum,
                        icon: const Icon(Icons.more_horiz, size: 19),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title.isEmpty ? '无标题' : title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (item.summary.isNotEmpty &&
                            item.summary != title) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            item.summary,
                            maxLines: switch (density) {
                              FeedDensity.compact => 2,
                              FeedDensity.standard => hasMedia ? 3 : 4,
                              FeedDensity.comfortable => hasMedia ? 4 : 6,
                            },
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  height: 1.35,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (hasMedia) ...<Widget>[
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 104,
                      height: 92,
                      child: FeedMediaPreview(
                        item: item,
                        borderRadius: BorderRadius.circular(10),
                        maxDimension: 480,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: InkWell(
                      onTap: onAuthorTap,
                      child: Row(
                        children: <Widget>[
                          AuthorAvatar(author: item.author, radius: 10),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item.author.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  CompactStat(
                    icon: Icons.thumb_up_alt_outlined,
                    value: item.stats.likes,
                  ),
                  const SizedBox(width: 12),
                  CompactStat(
                    icon: Icons.chat_bubble_outline,
                    value: item.stats.comments,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _relativeTime(DateTime value) {
  final difference = DateTime.now().difference(value.toLocal());
  if (difference.isNegative || difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes}分钟前';
  if (difference.inDays < 1) return '${difference.inHours}小时前';
  if (difference.inDays < 30) return '${difference.inDays}天前';
  final local = value.toLocal();
  return '${local.month}月${local.day}日';
}

class _Notices extends StatelessWidget {
  const _Notices({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
      child: Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.info_outline, size: 19),
              const SizedBox(width: 8),
              Expanded(child: Text(messages.join('\n'))),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
      child: Material(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 9),
              Expanded(child: Text(message)),
              IconButton(
                tooltip: '重试',
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
