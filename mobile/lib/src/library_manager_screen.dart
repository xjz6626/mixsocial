import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'detail_screen.dart';
import 'library_backup.dart';
import 'library_filter.dart';
import 'library_organizer.dart';
import 'media_tools.dart';
import 'models.dart';
import 'reading_state_store.dart';
import 'source_diagnostics.dart';

class LibraryManagerScreen extends StatefulWidget {
  const LibraryManagerScreen({super.key, required this.controller});
  final MixsocialController controller;
  @override
  State<LibraryManagerScreen> createState() => _LibraryManagerScreenState();
}

class _LibraryManagerScreenState extends State<LibraryManagerScreen> {
  final _search = TextEditingController();
  final _selected = <String>{};
  LibraryOrganization _organization = LibraryOrganization();
  List<FeedItem> _saved = [], _later = [];
  Map<String, ReadingState> _reading = {};
  String? _collection, _tag;
  SourceId _source = SourceId.all;
  bool _busy = true;
  int _loadVersion = 0;
  String? _error;
  LibraryOrganizerStore get _store => widget.controller.settings.organization;
  List<FeedItem> get _items => <String, FeedItem>{
    ..._organization.items,
    for (final item in _later) item.key: item,
    for (final item in _saved) item.key: item,
  }.values.toList();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final version = ++_loadVersion;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final organization = await _store.read();
      final saved = await widget.controller.savedItems();
      final later = await widget.controller.readLaterItems();
      final reading = await ReadingStateStore().all();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _organization = organization;
        _saved = saved;
        _later = later;
        _reading = reading;
        if (!_organization.collections.containsKey(_collection)) {
          _collection = null;
        }
        _selected.retainAll(_items.map((item) => item.key));
      });
    } catch (error) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = safeLocalMessage(error));
      }
    } finally {
      if (mounted && version == _loadVersion) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _mutate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _message('本地操作未全部完成：${safeLocalMessage(error)}；可重试，已保存的内容不会撤销');
    }
    if (mounted) await _load();
  }

  Future<String?> _prompt(String title, {String initial = '', String? hint}) =>
      showDialog<String>(
        context: context,
        builder: (context) =>
            _LibraryTextPrompt(title: title, initial: initial, hint: hint),
      );

  Future<void> _create() async {
    final name = await _prompt('新建本地收藏夹');
    if (name != null) await _mutate(() => _store.create(name));
  }

  Future<void> _manageCollection(String action) async {
    final name = _collection;
    if (name == null) return;
    if (action == 'rename') {
      final next = await _prompt('重命名收藏夹', initial: name);
      if (next != null) {
        await _mutate(() async {
          await _store.rename(name, next);
          _collection = next.trim();
        });
      }
    } else {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删除收藏夹“$name”？'),
          content: const Text(
            '只删除本地分类，不取消平台收藏，也不删除本地收藏和稍后阅读。仅保存在此收藏夹中的条目将不再显示。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (yes == true) await _mutate(() => _store.delete(name));
    }
  }

  Future<void> _chooseCollection(List<FeedItem> items) async {
    if (_organization.collections.isEmpty) {
      await _create();
      if (!mounted || _organization.collections.isEmpty) return;
    }
    if (!mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('加入本地收藏夹'),
        children: [
          for (final name in _organization.collections.keys)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, name),
              child: Text(name),
            ),
        ],
      ),
    );
    if (name != null) {
      await _mutate(() => _store.setMembership(name, items, true));
    }
  }

  Future<void> _itemAction(FeedItem item, String action) async {
    switch (action) {
      case 'collection':
        await _chooseCollection([item]);
      case 'tags':
        final value = await _prompt(
          '编辑标签',
          initial: (_organization.tags[item.key] ?? []).join('，'),
          hint: '用逗号分隔，最多 20 个标签',
        );
        if (value != null) {
          await _mutate(
            () => _store.setTags(item, value.split(RegExp('[,，\\n]'))),
          );
        }
      case 'saved':
        await _mutate(
          () => widget.controller.setLocalSaved(
            item,
            !_saved.any((value) => value.key == item.key),
          ),
        );
      case 'later':
        await _mutate(
          () => widget.controller.setReadLater(
            item,
            !_later.any((value) => value.key == item.key),
          ),
        );
      case 'complete':
        await _mutate(
          () => ReadingStateStore().setCompleted(
            item.key,
            _reading[item.key]?.completed != true,
          ),
        );
    }
  }

  Future<void> _batch(String action) async {
    final items = _items.where((item) => _selected.contains(item.key)).toList();
    if (items.isEmpty) return;
    if (action == 'collection') {
      await _chooseCollection(items);
      return;
    }
    if (action == 'removeCollection' && _collection != null) {
      await _mutate(() => _store.setMembership(_collection!, items, false));
      return;
    }
    if (action == 'unsave') {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('移除 ${items.length} 条本地收藏？'),
          content: const Text('不会取消平台收藏，不影响收藏夹和稍后阅读。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移除'),
            ),
          ],
        ),
      );
      if (yes != true) return;
    }
    await _mutate(() async {
      for (final item in items) {
        if (action == 'later') {
          await widget.controller.setReadLater(item, true);
        } else {
          await widget.controller.setLocalSaved(item, action == 'save');
        }
      }
    });
  }

  Future<void> _backup() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryBackupScreen(controller: widget.controller),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final visible =
        filterLibraryItems(items, query: _search.text, source: _source)
            .where(
              (item) =>
                  (_collection == null ||
                      (_organization.collections[_collection] ?? []).contains(
                        item.key,
                      )) &&
                  (_tag == null ||
                      (_organization.tags[item.key] ?? []).contains(_tag)),
            )
            .toList();
    final tags =
        _organization.tags.values.expand((values) => values).toSet().toList()
          ..sort();
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地收藏夹与标签'),
        actions: [
          IconButton(
            tooltip: '备份与恢复',
            onPressed: _busy ? null : _backup,
            icon: const Icon(Icons.import_export),
          ),
          IconButton(
            tooltip: '新建收藏夹',
            onPressed: _busy ? null : _create,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          if (_collection != null)
            PopupMenuButton<String>(
              enabled: !_busy,
              onSelected: _manageCollection,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名收藏夹')),
                PopupMenuItem(value: 'delete', child: Text('删除收藏夹')),
              ],
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (!_busy) await _load();
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('仅管理本机内容，不更改贴吧或小红书的平台收藏。长按条目可批量整理。'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '搜索标题、摘要、作者',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final source in SourceId.values)
                          ChoiceChip(
                            label: Text(source.label),
                            selected: _source == source,
                            onSelected: (_) => setState(() => _source = source),
                          ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: Text('全部 ${items.length}'),
                          selected: _collection == null,
                          onSelected: (_) => setState(() => _collection = null),
                        ),
                        for (final entry in _organization.collections.entries)
                          ChoiceChip(
                            label: Text('${entry.key} ${entry.value.length}'),
                            selected: _collection == entry.key,
                            onSelected: (_) =>
                                setState(() => _collection = entry.key),
                          ),
                      ],
                    ),
                    if (tags.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        children: [
                          FilterChip(
                            label: const Text('全部标签'),
                            selected: _tag == null,
                            onSelected: (_) => setState(() => _tag = null),
                          ),
                          for (final tag in tags)
                            FilterChip(
                              label: Text(tag),
                              selected: _tag == tag,
                              onSelected: (value) =>
                                  setState(() => _tag = value ? tag : null),
                            ),
                        ],
                      ),
                    Text(
                      '显示 ${visible.length} 条${_selected.isEmpty ? '' : ' · 已选 ${_selected.length} 条'}',
                    ),
                    if (_selected.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        children: [
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(
                                    () => _selected.addAll(
                                      visible.map((item) => item.key),
                                    ),
                                  ),
                            child: const Text('全选当前筛选'),
                          ),
                          TextButton(
                            onPressed: () => setState(_selected.clear),
                            child: const Text('取消选择'),
                          ),
                          PopupMenuButton<String>(
                            enabled: !_busy,
                            onSelected: _batch,
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'collection',
                                child: Text('加入收藏夹'),
                              ),
                              if (_collection != null)
                                const PopupMenuItem(
                                  value: 'removeCollection',
                                  child: Text('移出当前收藏夹'),
                                ),
                              const PopupMenuItem(
                                value: 'save',
                                child: Text('加入本地收藏'),
                              ),
                              const PopupMenuItem(
                                value: 'unsave',
                                child: Text('移出本地收藏'),
                              ),
                              const PopupMenuItem(
                                value: 'later',
                                child: Text('加入稍后阅读'),
                              ),
                            ],
                            child: const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('批量操作'),
                            ),
                          ),
                        ],
                      ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_busy)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
            if (!_busy && visible.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('没有匹配内容。先收藏帖子或加入稍后阅读。')),
              ),
            SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final item = visible[index];
                final selected = _selected.contains(item.key);
                return ListTile(
                  key: Key('organized-${item.key}'),
                  leading: _selected.isEmpty
                      ? Icon(
                          _reading[item.key]?.completed == true
                              ? Icons.task_alt
                              : Icons.article_outlined,
                        )
                      : Checkbox(
                          value: selected,
                          onChanged: _busy
                              ? null
                              : (_) => setState(
                                  () => selected
                                      ? _selected.remove(item.key)
                                      : _selected.add(item.key),
                                ),
                        ),
                  title: Text(
                    item.title.isEmpty ? item.summary : item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      item.ref.source.label,
                      if (_saved.any((value) => value.key == item.key)) '本地收藏',
                      if (_later.any((value) => value.key == item.key)) '稍后阅读',
                      if (_reading[item.key] != null) _reading[item.key]!.label,
                      ...?_organization.tags[item.key],
                    ].join(' · '),
                  ),
                  onLongPress: _busy
                      ? null
                      : () => setState(() => _selected.add(item.key)),
                  onTap: _busy
                      ? null
                      : () async {
                          if (_selected.isNotEmpty) {
                            setState(
                              () => selected
                                  ? _selected.remove(item.key)
                                  : _selected.add(item.key),
                            );
                            return;
                          }
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DetailScreen(
                                controller: widget.controller,
                                initialItem: item,
                              ),
                            ),
                          );
                          if (mounted) await _load();
                        },
                  trailing: PopupMenuButton<String>(
                    enabled: !_busy,
                    onSelected: (action) => _itemAction(item, action),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'collection',
                        child: Text('加入收藏夹'),
                      ),
                      const PopupMenuItem(value: 'tags', child: Text('编辑标签')),
                      PopupMenuItem(
                        value: 'saved',
                        child: Text(
                          _saved.any((value) => value.key == item.key)
                              ? '移出本地收藏'
                              : '加入本地收藏',
                        ),
                      ),
                      PopupMenuItem(
                        value: 'later',
                        child: Text(
                          _later.any((value) => value.key == item.key)
                              ? '移出稍后阅读'
                              : '加入稍后阅读',
                        ),
                      ),
                      PopupMenuItem(
                        value: 'complete',
                        child: Text(
                          _reading[item.key]?.completed == true
                              ? '标为未读'
                              : '标为已读',
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

class _LibraryTextPrompt extends StatefulWidget {
  const _LibraryTextPrompt({
    required this.title,
    required this.initial,
    this.hint,
  });
  final String title;
  final String initial;
  final String? hint;
  @override
  State<_LibraryTextPrompt> createState() => _LibraryTextPromptState();
}

class _LibraryTextPromptState extends State<_LibraryTextPrompt> {
  late final _input = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _input,
      autofocus: true,
      maxLength: widget.title == '编辑标签' ? 819 : 60,
      decoration: InputDecoration(hintText: widget.hint),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _input.text),
        child: const Text('保存'),
      ),
    ],
  );
}

class LibraryBackupScreen extends StatefulWidget {
  const LibraryBackupScreen({super.key, required this.controller});
  final MixsocialController controller;
  @override
  State<LibraryBackupScreen> createState() => _LibraryBackupScreenState();
}

class _LibraryBackupScreenState extends State<LibraryBackupScreen> {
  final _input = TextEditingController();
  LibraryBackup? _preview;
  bool _busy = false;
  String? _status;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _status = safeLocalMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export({bool share = false}) => _run(() async {
    final text = LibraryBackup.encode(
      saved: await widget.controller.savedItems(),
      readLater: await widget.controller.readLaterItems(),
      organization: await widget.controller.settings.organization.read(),
    );
    if (share) {
      await MediaTools.shareTextFile(text, fileName: 'mixsocial-library.json');
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (mounted) {
      setState(
        () => _status = share
            ? '已打开系统文件分享。请选择安全的位置保存备份。'
            : '备份 JSON 已复制到剪贴板。请粘贴到安全的位置保存；剪贴板可被其他应用读取。',
      );
    }
  });

  Future<void> _import() => _run(() async {
    final backup = _preview;
    if (backup == null) return;
    final saved = await widget.controller.savedItems();
    final later = await widget.controller.readLaterItems();
    final store = widget.controller.settings.organization;
    final organization = await store.read();
    final savedKeys = saved.map((item) => item.key).toSet();
    final laterKeys = later.map((item) => item.key).toSet();
    if ({
              ...savedKeys,
              ...backup.entries
                  .where((entry) => entry.saved)
                  .map((entry) => entry.item.key),
            }.length >
            300 ||
        {
              ...laterKeys,
              ...backup.entries
                  .where((entry) => entry.readLater)
                  .map((entry) => entry.item.key),
            }.length >
            300) {
      throw const FormatException('合并后超过 300 条上限，请先整理；尚未修改内容');
    }
    if ({
          ...organization.collections.keys.map((name) => name.toLowerCase()),
          ...backup.collections.map((name) => name.toLowerCase()),
        }.length >
        100) {
      throw const FormatException('合并后超过 100 个收藏夹，尚未修改内容');
    }
    final existing = {
      ...organization.items,
      for (final item in later) item.key: item,
      for (final item in saved) item.key: item,
    };
    final mergedTags = {
      for (final entry in backup.entries)
        entry.item.key: LibraryOrganizerStore.normalizeTags([
          ...?organization.tags[entry.item.key],
          ...entry.tags,
        ]),
    };
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认合并备份？'),
        content: Text(
          '${backup.entries.length} 条内容、${backup.collections.length} 个收藏夹。\n保留已有内容，重复项合并，不修改任何平台收藏。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('合并导入'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    var completed = 0;
    try {
      for (final name in backup.collections) {
        await store.create(name);
      }
      for (final entry in backup.entries) {
        final item = existing[entry.item.key] ?? entry.item;
        if (entry.saved && !savedKeys.contains(item.key)) {
          await widget.controller.setLocalSaved(item, true);
        }
        if (entry.readLater && !laterKeys.contains(item.key)) {
          await widget.controller.setReadLater(item, true);
        }
        for (final name in entry.collections) {
          await store.setMembership(name, [item], true);
        }
        if (mergedTags[item.key]!.isNotEmpty) {
          await store.setTags(item, mergedTags[item.key]!);
        }
        completed++;
      }
    } catch (_) {
      throw StateError('已合并 $completed 条，部分写入失败。可以再次导入重试，不会删除已有内容。');
    }
    if (mounted) {
      setState(() {
        _status = '已合并 ${backup.entries.length} 条内容；没有发送平台互动请求。';
        _preview = null;
      });
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本地备份与恢复')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '备份仅含帖子公开文字、ID、本地收藏、稍后阅读、收藏夹和标签；不含 Cookie、BDUSS、登录凭据、访问 token、头像或媒体链接。小红书导入项可能需要重新搜索获取可访问链接。',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _export,
          icon: const Icon(Icons.copy),
          label: const Text('复制 JSON 备份'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _export(share: true),
          icon: const Icon(Icons.ios_share),
          label: const Text('分享 JSON 备份文件'),
        ),
        const Divider(height: 32),
        TextField(
          key: const Key('library-backup-input'),
          enabled: !_busy,
          controller: _input,
          minLines: 6,
          maxLines: 12,
          maxLength: LibraryBackup.maxBytes,
          onChanged: (_) => setState(() => _preview = null),
          decoration: const InputDecoration(
            labelText: '粘贴 JSON 备份',
            hintText: '先校验预览，再确认合并；最大 4 MiB',
          ),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final preview = LibraryBackup.decode(_input.text);
                  if (mounted) setState(() => _preview = preview);
                }),
          child: const Text('校验并预览'),
        ),
        if (_preview != null) ...[
          const SizedBox(height: 12),
          Text(
            '${_preview!.entries.length} 条内容 · 收藏 ${_preview!.savedCount} · 稍后阅读 ${_preview!.readLaterCount} · 收藏夹 ${_preview!.collections.length}',
          ),
          for (final entry in _preview!.entries.take(5))
            Text(
              '${entry.item.ref.source.label} · ${entry.item.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          FilledButton(
            onPressed: _busy ? null : _import,
            child: const Text('确认合并导入'),
          ),
        ],
        if (_busy) const LinearProgressIndicator(),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_status!),
          ),
      ],
    ),
  );
}
