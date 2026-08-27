import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import 'app_controller.dart';
import 'detail_screen.dart';
import 'feed_widgets.dart';
import 'login_screen.dart';
import 'models.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final MixsocialController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Map<SourceId, ScrollController> _scrollControllers =
      <SourceId, ScrollController>{};
  Timer? _scrollSaveTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
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
      scrollController.addListener(
        () => _scheduleScrollSave(source, scrollController),
      );
      _scrollControllers[source] = scrollController;
    }
    setState(() {});
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
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

  Future<void> _selectSource(SourceId source) async {
    final previous = widget.controller.source;
    final previousScroll = _scrollControllers[previous];
    if (previousScroll?.hasClients ?? false) {
      await widget.controller.settings.setScrollOffset(
        previous,
        previousScroll!.offset,
      );
    }
    await widget.controller.selectSource(source);
  }

  Future<void> _openSearch() async {
    final textController = TextEditingController(
      text: widget.controller.searchQuery,
    );
    final query = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('搜索内容'),
        content: TextField(
          key: const Key('feed-search-field'),
          controller: textController,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '输入关键词',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (String value) => Navigator.pop(context, value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, textController.text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    textController.dispose();
    if (query != null && mounted) await widget.controller.search(query);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _scrollSaveTimer?.cancel();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mixsocial'),
        actions: <Widget>[
          IconButton(
            tooltip: '搜索',
            onPressed: _openSearch,
            icon: const Icon(Icons.search),
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
          IconButton(
            tooltip: '账号与登录',
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AccountScreen(controller: controller),
              ),
            ),
            icon: const Icon(Icons.account_circle_outlined),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _SourceSelector(
            selected: controller.source,
            onSelected: _selectSource,
          ),
          _ChannelSelector(
            selected: controller.channel,
            onSelected: controller.selectChannel,
          ),
          if (controller.searchQuery.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: const Icon(Icons.search, size: 17),
                  label: Text('搜索：${controller.searchQuery}'),
                  onDeleted: () => controller.search(''),
                ),
              ),
            ),
          if (controller.loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _scrollControllers.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _FeedBody(
                    controller: controller,
                    scrollController: _scrollControllers[controller.source]!,
                    onOpen: (FeedItem item) => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => DetailScreen(
                          controller: controller,
                          initialItem: item,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SourceSelector extends StatelessWidget {
  const _SourceSelector({required this.selected, required this.onSelected});

  final SourceId selected;
  final ValueChanged<SourceId> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        children: FeedChannel.values
            .map(
              (FeedChannel channel) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(
                    key: Key('channel-${channel.id}'),
                    label: SizedBox(
                      width: double.infinity,
                      child: Text(channel.label, textAlign: TextAlign.center),
                    ),
                    selected: selected == channel,
                    onSelected: (_) => onSelected(channel),
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
  });

  final MixsocialController controller;
  final ScrollController scrollController;
  final ValueChanged<FeedItem> onOpen;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: CustomScrollView(
        key: PageStorageKey<String>('feed-${controller.source.id}'),
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          if (controller.error != null)
            SliverToBoxAdapter(
              child: _ErrorNotice(
                message: controller.error!,
                onRetry: controller.refresh,
              ),
            ),
          if (controller.notices.isNotEmpty)
            SliverToBoxAdapter(child: _Notices(messages: controller.notices)),
          if (controller.items.isEmpty && !controller.loading)
            const SliverFillRemaining(hasScrollBody: false, child: _EmptyFeed())
          else if (controller.layout == FeedLayout.masonry)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
              sliver: SliverMasonryGrid.count(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childCount: controller.items.length,
                itemBuilder: (BuildContext context, int index) =>
                    MasonryFeedCard(
                      item: controller.items[index],
                      onTap: () => onOpen(controller.items[index]),
                    ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (BuildContext context, int index) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: ListFeedCard(
                      item: controller.items[index],
                      onTap: () => onOpen(controller.items[index]),
                    ),
                  ),
                  childCount: controller.items.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class MasonryFeedCard extends StatelessWidget {
  const MasonryFeedCard({super.key, required this.item, required this.onTap});

  final FeedItem item;
  final VoidCallback onTap;

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
            FeedMediaPreview(item: item),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
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
                  const SizedBox(height: 9),
                  Row(
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
  const ListFeedCard({super.key, required this.item, required this.onTap});

  final FeedItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = item.title.isNotEmpty ? item.title : item.summary;
    return Card(
      key: Key('list-${item.ref.source.id}-${item.ref.id}'),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 112,
                child: FeedMediaPreview(
                  item: item,
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 118,
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
                        const SizedBox(height: 4),
                        Text(
                          item.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const Spacer(),
                      Row(
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
                          CompactStat(
                            icon: Icons.thumb_up_alt_outlined,
                            value: item.stats.likes,
                          ),
                          const SizedBox(width: 8),
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
            ],
          ),
        ),
      ),
    );
  }
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

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.inbox_outlined, size: 48),
          SizedBox(height: 12),
          Text('这里暂时没有内容'),
          SizedBox(height: 4),
          Text('下拉即可重新加载'),
        ],
      ),
    );
  }
}
