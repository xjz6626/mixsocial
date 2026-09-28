import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'media_tools.dart';
import 'network_media.dart';

class MediaCacheScreen extends StatefulWidget {
  const MediaCacheScreen({super.key});
  @override
  State<MediaCacheScreen> createState() => _MediaCacheScreenState();
}

class _MediaCacheScreenState extends State<MediaCacheScreen> {
  int? _temporaryBytes;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await MediaTools.temporaryCacheBytes();
      if (mounted) {
        setState(() {
          _temporaryBytes = bytes;
          _error = null;
        });
      }
    } on MissingPluginException {
      if (mounted) setState(() => _temporaryBytes = 0);
    } catch (_) {
      if (mounted) setState(() => _error = '未能读取临时文件大小，请重试');
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理图片缓存？'),
        content: const Text(
          '只清理内存图片和保存／分享操作生成的临时文件。不删除已保存图片、收藏、阅读记录或登录状态。尚未完成的外部分享可能需要重新发起。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      MediaCacheInfo.clearMemory();
      try {
        await MediaTools.clearTemporaryCache();
      } on MissingPluginException {
        /* no native cache */
      }
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('图片缓存已清理')));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '内存缓存已清理，临时文件未清理完成，请结束保存／分享后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('图片缓存'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          title: const Text('图片字节内存'),
          subtitle: Text('${MediaCacheInfo.nativeEntries} 项'),
          trailing: Text(_size(MediaCacheInfo.nativeBytes)),
        ),
        ListTile(
          title: const Text('Flutter 解码图片内存'),
          trailing: Text(_size(MediaCacheInfo.flutterBytes)),
        ),
        ListTile(
          title: const Text('图片／文件分享临时文件'),
          trailing: Text(
            _temporaryBytes == null ? '读取中' : _size(_temporaryBytes!),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('以上是应用图片内存和本应用分享临时目录，不包括 WebView 或平台登录缓存。重新浏览会再次加载图片。'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton.icon(
          onPressed: _busy ? null : _clear,
          icon: const Icon(Icons.cleaning_services_outlined),
          label: Text(_busy ? '清理中' : '清理图片缓存'),
        ),
      ],
    ),
  );
}
