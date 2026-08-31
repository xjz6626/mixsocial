import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'detail_screen.dart';
import 'forum_screen.dart';
import 'models.dart';

enum LocalLibraryKind { history, saved }

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

  bool get _history => widget.kind == LocalLibraryKind.history;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = _history
          ? await widget.controller.historyItems()
          : await widget.controller.savedItems();
      if (!mounted) return;
      setState(() => _items = items);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空浏览历史？'),
        content: const Text('该操作只删除本机记录，不影响平台账号。'),
        actions: <Widget>[
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
    if (confirmed != true) return;
    await widget.controller.clearHistory();
    if (mounted) setState(() => _items = const <FeedItem>[]);
  }

  Future<void> _toggleSaved(FeedItem item) async {
    await widget.controller.favorite(item, false);
    if (mounted) {
      setState(
        () => _items = _items.where((value) => value.key != item.key).toList(),
      );
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
    if (mounted && !_history) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_history ? '浏览历史' : '本地收藏'),
        actions: <Widget>[
          if (_history && _items.isNotEmpty)
            IconButton(
              tooltip: '清空历史',
              onPressed: _clearHistory,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: _loading
          ? AppLoadingView(
              title: _history ? '正在读取浏览历史' : '正在读取本地收藏',
              message: '数据只保存在这台设备上',
            )
          : _error != null
          ? AppStateView(
              icon: Icons.storage_outlined,
              iconColor: Theme.of(context).colorScheme.error,
              title: '本地内容读取失败',
              message: _error.toString(),
              actionLabel: '重试',
              onAction: _load,
            )
          : _items.isEmpty
          ? AppStateView(
              icon: _history
                  ? Icons.history_toggle_off_rounded
                  : Icons.bookmark_border_rounded,
              title: _history ? '还没有浏览记录' : '还没有收藏内容',
              message: _history
                  ? '打开过的帖子会自动出现在这里，方便稍后继续阅读。'
                  : '在帖子详情中点击收藏，即可把内容保存在本机。',
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (BuildContext context, int index) {
                  final item = _items[index];
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 860),
                      child: Card(
                        child: ListTile(
                          visualDensity: switch (widget.controller.density) {
                            FeedDensity.compact => VisualDensity.compact,
                            FeedDensity.standard => VisualDensity.standard,
                            FeedDensity.comfortable => const VisualDensity(
                              vertical: 1,
                            ),
                          },
                          contentPadding: const EdgeInsets.fromLTRB(
                            14,
                            8,
                            8,
                            8,
                          ),
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
                              ],
                            ),
                          ),
                          trailing: _history
                              ? const Icon(Icons.chevron_right)
                              : IconButton(
                                  tooltip: '取消收藏',
                                  onPressed: () => _toggleSaved(item),
                                  icon: const Icon(Icons.bookmark),
                                ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
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
