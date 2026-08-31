import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mixsocial_core/mixsocial_core.dart';

import 'models.dart';

const String mediaUserAgent =
    'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

String normalizeMediaUrl(String rawUrl) {
  var value = rawUrl.trim();
  if (value.isEmpty) return '';
  value = value
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll(r'\/', '/');
  if (value.startsWith('//')) return 'https:$value';
  return value;
}

Uri? mediaUri(String rawUrl, {bool preferHttps = false}) {
  final value = normalizeMediaUrl(rawUrl);
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return preferHttps && uri.scheme == 'http'
      ? uri.replace(scheme: 'https')
      : uri;
}

Map<String, String> mediaRequestHeaders(
  SourceId source, {
  bool video = false,
}) => <String, String>{
  'User-Agent': mediaUserAgent,
  'Accept': video
      ? 'video/*,application/vnd.apple.mpegurl,application/x-mpegURL,*/*;q=0.8'
      : 'image/jpeg,image/png,image/webp,image/*,*/*;q=0.8',
  if (source == SourceId.xhs) 'Referer': 'https://www.xiaohongshu.com/',
  if (source == SourceId.tieba) 'Referer': 'https://tieba.baidu.com/',
};

class SourceNetworkImage extends StatefulWidget {
  const SourceNetworkImage({
    super.key,
    required this.url,
    required this.source,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.errorBuilder,
    this.loadingBuilder,
    this.filterQuality = FilterQuality.medium,
    this.maxDimension = 1600,
    this.semanticLabel,
  });

  final String url;
  final SourceId source;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageLoadingBuilder? loadingBuilder;
  final FilterQuality filterQuality;
  final int maxDimension;
  final String? semanticLabel;

  @override
  State<SourceNetworkImage> createState() => _SourceNetworkImageState();
}

class _SourceNetworkImageState extends State<SourceNetworkImage> {
  Future<Uint8List>? _nativeBytes;
  Object? _lastError;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant SourceNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.source != widget.source ||
        oldWidget.maxDimension != widget.maxDimension) {
      _startLoad();
    }
  }

  void _startLoad({bool evict = false}) {
    _lastError = null;
    final uri = mediaUri(widget.url, preferHttps: true);
    if (uri == null ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      _nativeBytes = null;
      return;
    }
    final key = '${widget.maxDimension}:${uri.toString()}';
    if (evict) _NativeImageCache.evict(key);
    _nativeBytes = _NativeImageCache.load(
      key,
      () => _loadNativeWithFallback(uri),
    );
  }

  Future<Uint8List> _loadNativeWithFallback(Uri preferred) async {
    final original = mediaUri(widget.url);
    final attempts = <({Uri uri, Map<String, String> headers})>[
      (uri: preferred, headers: mediaRequestHeaders(widget.source)),
      (uri: preferred, headers: const <String, String>{}),
      if (original != null && original != preferred)
        (uri: original, headers: mediaRequestHeaders(widget.source)),
    ];
    Object? lastError;
    for (final attempt in attempts) {
      try {
        return await MixsocialCore.fetchImage(
          attempt.uri.toString(),
          headers: attempt.headers,
          maxDimension: widget.maxDimension,
        );
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('媒体加载失败');
  }

  @override
  Widget build(BuildContext context) {
    final normalized = normalizeMediaUrl(widget.url);
    final uri = mediaUri(normalized, preferHttps: true);
    if (uri == null) {
      return widget.errorBuilder?.call(
            context,
            StateError('无效的媒体地址'),
            StackTrace.current,
          ) ??
          const SizedBox.shrink();
    }
    final nativeBytes = _nativeBytes;
    if (nativeBytes != null) {
      return FutureBuilder<Uint8List>(
        future: nativeBytes,
        builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
          if (snapshot.hasData) {
            return Image.memory(
              snapshot.requireData,
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              alignment: widget.alignment,
              filterQuality: widget.filterQuality,
              gaplessPlayback: true,
              semanticLabel: widget.semanticLabel,
              errorBuilder: (context, error, stackTrace) =>
                  _error(context, error, stackTrace),
            );
          }
          if (snapshot.hasError) {
            _lastError = snapshot.error;
            return _networkFallback(uri);
          }
          return widget.loadingBuilder?.call(
                context,
                SizedBox(width: widget.width, height: widget.height),
                null,
              ) ??
              Semantics(
                label: widget.semanticLabel == null
                    ? '正在加载媒体'
                    : '正在加载${widget.semanticLabel}',
                child: Center(
                  child: Icon(
                    Icons.image_outlined,
                    size: 24,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              );
        },
      );
    }
    return _networkFallback(uri);
  }

  Widget _networkFallback(Uri uri) => Image.network(
    uri.toString(),
    headers: mediaRequestHeaders(widget.source),
    width: widget.width,
    height: widget.height,
    fit: widget.fit,
    alignment: widget.alignment,
    filterQuality: widget.filterQuality,
    gaplessPlayback: true,
    semanticLabel: widget.semanticLabel,
    errorBuilder: (context, error, stackTrace) {
      final nativeError = _lastError;
      return _error(
        context,
        nativeError == null
            ? error
            : StateError('原生加载失败：$nativeError；Flutter 加载失败：$error'),
        stackTrace,
      );
    },
    loadingBuilder: widget.loadingBuilder,
  );

  Widget _error(BuildContext context, Object error, StackTrace? stackTrace) {
    final fallback =
        widget.errorBuilder?.call(
          context,
          error,
          stackTrace ?? StackTrace.current,
        ) ??
        const Center(child: Icon(Icons.broken_image_outlined));
    return Semantics(
      button: true,
      label: '媒体加载失败，点按重试',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _startLoad(evict: true)),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            fallback,
            Positioned(
              right: 5,
              bottom: 5,
              child: Tooltip(
                message: error.toString(),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.refresh, size: 15, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NativeImageCache {
  static const int _maximumBytes = 48 * 1024 * 1024;
  static final LinkedHashMap<String, Uint8List> _values =
      LinkedHashMap<String, Uint8List>();
  static final Map<String, Future<Uint8List>> _pending =
      <String, Future<Uint8List>>{};
  static int _currentBytes = 0;

  static Future<Uint8List> load(
    String key,
    Future<Uint8List> Function() loader,
  ) {
    final cached = _values.remove(key);
    if (cached != null) {
      _values[key] = cached;
      return SynchronousFuture<Uint8List>(cached);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final value = await loader();
        _put(key, value);
        return value;
      } finally {
        _pending.remove(key);
      }
    });
  }

  static void evict(String key) {
    final value = _values.remove(key);
    if (value != null) _currentBytes -= value.lengthInBytes;
    _pending.remove(key);
  }

  static void _put(String key, Uint8List value) {
    if (value.lengthInBytes > _maximumBytes) return;
    final previous = _values.remove(key);
    if (previous != null) _currentBytes -= previous.lengthInBytes;
    _values[key] = value;
    _currentBytes += value.lengthInBytes;
    while (_currentBytes > _maximumBytes && _values.isNotEmpty) {
      final oldestKey = _values.keys.first;
      final removed = _values.remove(oldestKey)!;
      _currentBytes -= removed.lengthInBytes;
    }
  }
}
