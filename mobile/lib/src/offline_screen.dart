import 'package:flutter/material.dart';

import 'offline_store.dart';
import 'structured_body.dart';
import 'source_diagnostics.dart';
import 'app_controller.dart';

class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({super.key, required this.controller});
  final MixsocialController controller;
  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  final _store = OfflineStore();
  late Future<List<OfflineEntry>> _entries = _store.list();
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('离线下载')),
      body: FutureBuilder<List<OfflineEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(safeLocalMessage(snapshot.error!)));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.requireData
              .where(
                (entry) => !widget.controller.isItemBlocked(entry.detail.item),
              )
              .toList();
          if (entries.isEmpty) {
            return Center(
              child: Text(
                snapshot.requireData.isEmpty
                    ? '还没有下载\n在内容详情菜单中选择“下载离线正文与图片”'
                    : '已下载内容被屏蔽规则隐藏\n可在“内容与阅读设置”中解除屏蔽，下载副本仍然保留',
                textAlign: TextAlign.center,
              ),
            );
          }
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '显示 ${entries.length} / ${snapshot.requireData.length} 条 · ${(snapshot.requireData.fold<int>(0, (total, entry) => total + entry.bytes) / 1048576).toStringAsFixed(1)} / 200 MiB\n下载不会随图片缓存清理。原站内容可能更新或删除。',
                ),
              ),
              for (final entry in entries)
                ListTile(
                  title: Text(
                    entry.detail.item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${entry.detail.item.ref.source.label} · ${entry.imageCount} 张图片 · ${(entry.bytes / 1024).ceil()} KiB\n${entry.savedAt.toLocal().toString().split('.').first}',
                  ),
                  onTap: () async {
                    try {
                      final saved = await _store.read(entry.detail.item.key);
                      if (context.mounted && saved != null) {
                        await Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => OfflineReadingScreen(entry: saved),
                          ),
                        );
                      }
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(safeLocalMessage(error))),
                        );
                      }
                    }
                  },
                  trailing: IconButton(
                    tooltip: '删除离线副本',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      try {
                        await _store.remove(entry.detail.item.key);
                        if (mounted) setState(() => _entries = _store.list());
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(safeLocalMessage(error))),
                          );
                        }
                      }
                    },
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

/// This route deliberately has no network image, video, or source-controller
/// dependency, so opening a saved copy cannot make background site requests.
class OfflineReadingScreen extends StatelessWidget {
  const OfflineReadingScreen({super.key, required this.entry});
  final OfflineEntry entry;
  @override
  Widget build(BuildContext context) {
    final detail = entry.detail;
    final blocks = detail.contentHtml.isNotEmpty
        ? parseReadingBlocks(detail.contentHtml)
        : [ReadingBlock('text', text: detail.body)];
    return Scaffold(
      appBar: AppBar(title: const Text('离线正文')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SelectableText(
            detail.item.title,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '${detail.item.author.name} · ${entry.savedAt.toLocal().toString().split('.').first}\n仅包含已下载正文和选定图片，评论及视频需在线查看。',
          ),
          const Divider(height: 32),
          for (final block in blocks)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: block.kind == 'image'
                  ? entry.images.containsKey(block.media!.fullImageUrl)
                        ? Image.memory(entry.images[block.media!.fullImageUrl]!)
                        : const Text('此图片未下载')
                  : SelectableText(
                      block.kind == 'link'
                          ? '${block.text}\n${block.url}'
                          : block.text,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(height: 1.7),
                    ),
            ),
          if (detail.contentHtml.isEmpty)
            for (final image in entry.images.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Image.memory(image),
              ),
        ],
      ),
    );
  }
}
