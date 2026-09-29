import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'detail_screen.dart';
import 'forum_screen.dart';
import 'library_filter.dart';
import 'library_manager_screen.dart';
import 'models.dart';
import 'reading_state_store.dart';
import 'source_diagnostics.dart';

enum LocalLibraryKind {
  history('浏览历史', Icons.history_toggle_off_rounded),
  saved('本地收藏', Icons.bookmark_border_rounded),
  readLater('稍后阅读', Icons.schedule_outlined);

  const LocalLibraryKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

class LocalLibraryScreen extends StatefulWidget {
  const LocalLibraryScreen({
    super.key,
    required this.controller,
    required this.kind,
  });

  final MixsocialController controller;
  final LocalLibraryKind kind;

  @override
  State<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

class _LocalLibraryScreenState extends State<LocalLibraryScreen> {
  List<FeedItem> _items = const <FeedItem>[];
  bool _loading = true;
  Object? _error;
  final TextEditingController _searchController = TextEditingController();
  SourceId _source = SourceId.all;
  int _requestVersion = 0;
  bool _working = false;
  Completer<void>? _editFinished;
  Map<String, ReadingState> _reading = {};

  bool get _history => widget.kind == LocalLibraryKind.history;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_working) return;
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await switch (widget.kind) {
        LocalLibraryKind.history => widget.controller.historyItems(),
        LocalLibraryKind.saved => widget.controller.savedItems(),
        LocalLibraryKind.readLater => widget.controller.readLaterItems(),
      };
      final reading = await ReadingStateStore().all();
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _items = items;
        _reading = reading;
      });
    } catch (error) {
      if (mounted && version == _requestVersion) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && version == _requestVersion) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _clearHistory() async {
    if (_working) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空浏览历史？'),
        content: const Text('清空所有平台的本机浏览记录，包含当前筛选之外的记录。'),
        actions: <Widget>[
          IconButton(
            tooltip: '收藏夹与标签',
            onPressed: () async {
              await Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      LibraryManagerScreen(controller: widget.controller),
                ),
              );
              if (mounted) await _load();
            },
            icon: const Icon(Icons.folder_open_outlined),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _working) return;
    _requestVersion++;
    setState(() {
      _working = true;
      _loading = false;
    });
    try {
      await widget.controller.clearHistory();
      if (mounted) {
        setState(() {
          _items = const <FeedItem>[];
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) _message('清空历史失败：${safeLocalMessage(error)}');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _setPresent(FeedItem item, bool value) async {
    if (!mounted || _working) return;
    final finished = Completer<void>();
    _editFinished = finished;
    _requestVersion++;
    setState(() {
      _working = true;
      _loading = false;
    });
    try {
      if (widget.kind == LocalLibraryKind.readLater) {
        await widget.controller.setReadLater(item, value);
      } else {
        await widget.controller.setLocalSaved(item, value);
      }
      if (!mounted) return;
      setState(() {
        _error = null;
        _items = <FeedItem>[
          if (value) item,
          ..._items.where((existing) => existing.key != item.key),
        ];
      });
      _message(
        value ? '已恢复${widget.kind.label}' : '已移出${widget.kind.label}',
        action: value
            ? null
            : SnackBarAction(
                label: '撤销',
                onPressed: () => unawaited(_restore(item)),
              ),
      );
    } catch (error) {
      if (mounted) _message('本地内容更新失败：${safeLocalMessage(error)}');
    } finally {
      if (mounted) setState(() => _working = false);
      _editFinished = null;
      finished.complete();
    }
  }

  Future<void> _restore(FeedItem item) async {
    final pending = _editFinished;
    if (pending != null) await pending.future;
    if (mounted) await _setPresent(item, true);
  }

  Future<void> _markCompleted(FeedItem item) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await ReadingStateStore().setCompleted(
        item.key,
        _reading[item.key]?.completed != true,
      );
    } catch (error) {
      if (mounted) _message('阅读状态保存失败：${safeLocalMessage(error)}');
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (mounted) await _load();
  }

  void _message(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<void> _open(FeedItem item) async {
    try {
      await widget.controller.recordHistory(item);
    } catch (_) {
      if (mounted) _message('浏览记录保存失败，仍可继续阅读');
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            DetailScreen(controller: widget.controller, initialItem: item),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = filterLibraryItems(
      _items,
      query: _searchController.text,
      source: _source,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.kind.label),
        actions: <Widget>[
          if (_history && _items.isNotEmpty)
            IconButton(
              tooltip: '清空历史',
              onPressed: _working ? null : _clearHistory,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        TextField(
                          key: const Key('library-search'),
                          controller: _searchController,
                          onChanged: (_) => setState(() {}),
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            labelText: '搜索${widget.kind.label}',
                            hintText: '标题、摘要、作者或吧名',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchController.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清除搜索',
                                    onPressed: () => setState(
                                      () => _searchController.clear(),
                                    ),
                                    icon: const Icon(Icons.close),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: SourceId.values
                              .map(
                                (source) => ChoiceChip(
                                  key: Key('library-source-${source.id}'),
                                  label: Text(source.label),
                                  selected: source == _source,
                                  onSelected: (_) =>
                                      setState(() => _source = source),
                                ),
                              )
                              .toList(),
                        ),
                        if (!_loading)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '显示 ${visible.length} / ${_items.length} 条',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_working)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            _buildContents(visible),
          ],
        ),
      ),
    );
  }

  Widget _buildContents(List<FeedItem> visible) => _loading
      ? _fillState(
          AppLoadingView(
            title: '正在读取${widget.kind.label}',
            message: '数据只保存在这台设备上',
          ),
        )
      : _error != null
      ? _fillState(
          AppStateView(
            icon: Icons.storage_outlined,
            iconColor: Theme.of(context).colorScheme.error,
            title: '本地内容读取失败',
            message: safeLocalMessage(_error!),
            actionLabel: '重试',
            onAction: _load,
          ),
        )
      : _items.isEmpty
      ? _fillState(
          AppStateView(
            icon: widget.kind.icon,
            title: '还没有${widget.kind.label}内容',
            message: switch (widget.kind) {
              LocalLibraryKind.history => '打开过的帖子会出现在这里，方便再次查找。',
              LocalLibraryKind.saved => '已保存在本机的收藏会出现在这里。',
              LocalLibraryKind.readLater =>
                '在帖子详情的更多菜单中加入稍后阅读，方便下次找到。阅读正文仍需连接平台。',
            },
          ),
        )
      : visible.isEmpty
      ? _fillState(
          AppStateView(
            icon: Icons.search_off,
            title: '没有匹配的内容',
            message: '换一个关键词或平台试试。',
            actionLabel: '清除筛选',
            onAction: () => setState(() {
              _source = SourceId.all;
              _searchController.clear();
            }),
          ),
        )
      : SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
          sliver: SliverList.separated(
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (BuildContext context, int index) {
              final item = visible[index];
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: Card(
                    child: ListTile(
                      key: Key('library-item-${item.key}'),
                      visualDensity: switch (widget.controller.density) {
                        FeedDensity.compact => VisualDensity.compact,
                        FeedDensity.standard => VisualDensity.standard,
                        FeedDensity.comfortable => const VisualDensity(
                          vertical: 1,
                        ),
                      },
                      contentPadding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                      onTap: () => _open(item),
                      title: Text(
                        item.title.isEmpty ? item.summary : item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 8,
                          children: <Widget>[
                            Text(item.ref.source.label),
                            if (item.forumName.isNotEmpty)
                              InkWell(
                                onTap: () => Navigator.push<void>(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => ForumScreen(
                                      controller: widget.controller,
                                      forum: item.forumName,
                                    ),
                                  ),
                                ),
                                child: Text('${item.forumName}吧'),
                              ),
                            Text(item.author.name),
                            if (_reading[item.key] != null)
                              Text(_reading[item.key]!.label),
                          ],
                        ),
                      ),
                      trailing: _history
                          ? const Icon(Icons.chevron_right)
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.kind == LocalLibraryKind.readLater)
                                  IconButton(
                                    tooltip:
                                        _reading[item.key]?.completed == true
                                        ? '标为未读'
                                        : '标为已读',
                                    onPressed: _working
                                        ? null
                                        : () => _markCompleted(item),
                                    icon: Icon(
                                      _reading[item.key]?.completed == true
                                          ? Icons.task_alt
                                          : Icons.radio_button_unchecked,
                                    ),
                                  ),
                                IconButton(
                                  key: Key('library-remove-${item.key}'),
                                  tooltip: '移出${widget.kind.label}',
                                  onPressed: _working
                                      ? null
                                      : () => _setPresent(item, false),
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        );

  Widget _fillState(Widget child) =>
      SliverFillRemaining(hasScrollBody: false, child: child);
}

class ContentSettingsScreen extends StatefulWidget {
  const ContentSettingsScreen({super.key, required this.controller});

  final MixsocialController controller;

  @override
  State<ContentSettingsScreen> createState() => _ContentSettingsScreenState();
}

class _ContentSettingsScreenState extends State<ContentSettingsScreen> {
  Future<void> _addForum() async {
    final value = await _prompt('添加屏蔽吧', '输入吧名');
    if (value == null) return;
    await widget.controller.setForumBlocked(value, true);
    if (mounted) setState(() {});
  }

  Future<void> _addKeyword() async {
    final value = await _prompt('添加屏蔽关键词', '标题或正文包含该词时隐藏');
    if (value == null) return;
    await widget.controller.setKeywordBlocked(value, true);
    if (mounted) setState(() {});
  }

  Future<String?> _prompt(String title, String hint) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (String value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final forums = widget.controller.blockedForums.toList()..sort();
    final keywords = widget.controller.blockedKeywords.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('内容与阅读设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('外观', style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<AppThemePreference>(
                segments: AppThemePreference.values
                    .map(
                      (AppThemePreference value) =>
                          ButtonSegment<AppThemePreference>(
                            value: value,
                            icon: Icon(value.icon),
                            label: Text(value.label),
                          ),
                    )
                    .toList(),
                selected: <AppThemePreference>{
                  widget.controller.themePreference,
                },
                showSelectedIcon: false,
                onSelectionChanged: (Set<AppThemePreference> values) async {
                  await widget.controller.setThemePreference(values.single);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
          const Divider(height: 32),
          SwitchListTile(
            secondary: const Icon(Icons.hide_image_outlined),
            title: const Text('隐藏全部媒体'),
            subtitle: const Text('保留文字内容，不加载图片和视频'),
            value: widget.controller.hideMedia,
            onChanged: (bool value) async {
              await widget.controller.setHideMedia(value);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.videocam_off_outlined),
            title: const Text('隐藏视频内容'),
            subtitle: const Text('隐藏包含视频的整条内容'),
            value: widget.controller.hideVideos,
            onChanged: (bool value) async {
              await widget.controller.setHideVideos(value);
              if (mounted) setState(() {});
            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('阅读密度', style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<FeedDensity>(
              segments: FeedDensity.values
                  .map(
                    (FeedDensity value) => ButtonSegment<FeedDensity>(
                      value: value,
                      label: Text(value.label),
                    ),
                  )
                  .toList(),
              selected: <FeedDensity>{widget.controller.density},
              onSelectionChanged: (Set<FeedDensity> values) async {
                await widget.controller.setDensity(values.single);
                if (mounted) setState(() {});
              },
            ),
          ),
          const Divider(height: 32),
          _RuleHeader(title: '屏蔽的吧', count: forums.length, onAdd: _addForum),
          if (forums.isEmpty)
            const ListTile(title: Text('未屏蔽任何贴吧'))
          else
            for (final forum in forums)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: Text('$forum吧'),
                trailing: IconButton(
                  tooltip: '解除屏蔽',
                  onPressed: () async {
                    await widget.controller.setForumBlocked(forum, false);
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
              ),
          const Divider(height: 24),
          _RuleHeader(
            title: '屏蔽关键词',
            count: keywords.length,
            onAdd: _addKeyword,
          ),
          if (keywords.isEmpty)
            const ListTile(title: Text('未设置屏蔽关键词'))
          else
            for (final keyword in keywords)
              ListTile(
                leading: const Icon(Icons.text_fields),
                title: Text(keyword),
                trailing: IconButton(
                  tooltip: '删除关键词',
                  onPressed: () async {
                    await widget.controller.setKeywordBlocked(keyword, false);
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
              ),
        ],
      ),
    );
  }
}

class _RuleHeader extends StatelessWidget {
  const _RuleHeader({
    required this.title,
    required this.count,
    required this.onAdd,
  });

  final String title;
  final int count;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text('$count 条规则'),
      trailing: FilledButton.tonalIcon(
        onPressed: onAdd,
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
    );
  }
}
