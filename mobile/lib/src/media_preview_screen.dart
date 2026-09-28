import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'media_tools.dart';
import 'models.dart';
import 'network_media.dart';

class MediaPreviewScreen extends StatefulWidget {
  const MediaPreviewScreen({
    super.key,
    required this.source,
    required this.media,
    this.mediaItems = const [],
    this.initialIndex,
  });

  final SourceId source;
  final MediaItem media;
  final List<MediaItem> mediaItems;
  final int? initialIndex;

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  late final List<MediaItem> _images;
  late final List<TransformationController> _transforms;
  late final PageController _pages;
  late int _index;
  bool _busy = false;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _images = widget.mediaItems.where((item) => item.kind != 'video').toList();
    if (_images.isEmpty) _images.add(widget.media);
    final selected = _images.indexWhere((item) => item.url == widget.media.url);
    _index = (widget.initialIndex ?? (selected < 0 ? 0 : selected)).clamp(
      0,
      _images.length - 1,
    );
    _pages = PageController(initialPage: _index);
    _transforms = List.generate(
      _images.length,
      (_) => TransformationController(),
    );
    for (var index = 0; index < _transforms.length; index++) {
      _transforms[index].addListener(() {
        if (!mounted || index != _index) return;
        final zoomed = _transforms[index].value.getMaxScaleOnAxis() > 1.01;
        if (_zoomed != zoomed) setState(() => _zoomed = zoomed);
      });
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final transform in _transforms) {
      transform.dispose();
    }
    super.dispose();
  }

  Future<void> _action(bool save) async {
    if (_busy) return;
    final media = _images[_index];
    setState(() => _busy = true);
    try {
      await MediaTools.image(media, widget.source, save: save);
      if (mounted && save) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('图片已保存')));
      }
    } on PlatformException catch (error) {
      if (error.code != 'cancelled') _message(error.message ?? '图片操作失败，请重试');
    } catch (_) {
      _message('图片操作失败，可能是地址不受支持或网络不可用');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> _showActions() async {
    if (_busy) return;
    final action = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('保存图片'),
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享图片'),
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    );
    if (action != null && mounted) await _action(action);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      foregroundColor: Colors.white,
      backgroundColor: Colors.black,
      title: Text(
        _images.length > 1 ? '${_index + 1}/${_images.length}' : '查看图片',
      ),
      actions: [
        IconButton(
          tooltip: '复原图片',
          onPressed: () => _transforms[_index].value = Matrix4.identity(),
          icon: const Icon(Icons.fit_screen_rounded),
        ),
        IconButton(
          tooltip: '保存图片',
          onPressed: _busy ? null : () => _action(true),
          icon: const Icon(Icons.download_outlined),
        ),
        IconButton(
          tooltip: '分享图片',
          onPressed: _busy ? null : () => _action(false),
          icon: const Icon(Icons.share_outlined),
        ),
      ],
      bottom: _busy
          ? const PreferredSize(
              preferredSize: Size.fromHeight(2),
              child: LinearProgressIndicator(minHeight: 2),
            )
          : null,
    ),
    body: PageView.builder(
      controller: _pages,
      physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
      itemCount: _images.length,
      onPageChanged: (index) => setState(() {
        _index = index;
        _zoomed = _transforms[index].value.getMaxScaleOnAxis() > 1.01;
      }),
      itemBuilder: (context, index) => LayoutBuilder(
        builder: (context, constraints) {
          final media = _images[index];
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          final sourceSize = media.width > 0 && media.height > 0
              ? Size(media.width.toDouble(), media.height.toDouble())
              : viewport;
          final fitted = applyBoxFit(
            BoxFit.contain,
            sourceSize,
            viewport,
          ).destination;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: _showActions,
            onDoubleTap: () => _transforms[index].value = Matrix4.identity(),
            child: InteractiveViewer(
              key: index == _index
                  ? const Key('media-preview-interactive-viewer')
                  : ValueKey('media-preview-$index'),
              transformationController: _transforms[index],
              constrained: false,
              alignment: Alignment.center,
              boundaryMargin: EdgeInsets.all(viewport.longestSide * .25),
              minScale: 1,
              maxScale: 8,
              panEnabled: true,
              scaleEnabled: true,
              trackpadScrollCausesScale: true,
              child: SizedBox(
                width: fitted.width,
                height: fitted.height,
                child: ProgressiveSourceNetworkImage(
                  media: media,
                  source: widget.source,
                  quality: MediaImageQuality.original,
                  width: fitted.width,
                  height: fitted.height,
                  fit: BoxFit.contain,
                  maxDimension: 4096,
                  previewMaxDimension: 1280,
                  semanticLabel: '帖子图片，可双指缩放和拖动，长按保存或分享',
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 54,
                    ),
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
