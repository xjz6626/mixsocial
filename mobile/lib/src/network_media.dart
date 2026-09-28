import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mixsocial_core/mixsocial_core.dart';

import 'models.dart';

enum MediaImageQuality { thumbnail, detail, original }

const String mediaUserAgent =
    'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

String normalizeMediaUrl(String rawUrl) {
  var value = rawUrl.trim();
  if (value.isEmpty) return '';
  value = value
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll(r'\u0026', '&')
      .replaceAll(r'\/', '/');
  if (value.startsWith('//')) return 'https:$value';
  return value;
}

List<String> avatarImageCandidates(Author author) {
  final seen = <String>{};
  return <String>[author.avatar, ...author.avatarUrls]
      .map((url) => mediaUri(url)?.toString())
      .whereType<String>()
      .where(seen.add)
      .toList();
}

Uri? mediaUri(String rawUrl, {bool preferHttps = false}) {
  final value = normalizeMediaUrl(rawUrl);
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return preferHttps && uri.scheme == 'http'
      ? uri.replace(scheme: 'https')
      : uri;
}

String xhsOriginalImageUrl(String rawUrl) {
  final normalized = normalizeMediaUrl(rawUrl);
  final uri = mediaUri(normalized, preferHttps: true);
  if (uri == null ||
      !(uri.host == 'xhscdn.com' || uri.host.endsWith('.xhscdn.com'))) {
    return normalized;
  }
  final marker = uri.path.lastIndexOf('!');
  if (marker <= uri.path.lastIndexOf('/')) return uri.toString();
  final transformation = uri.path.substring(marker + 1).toLowerCase();
  final isKnownVariant = RegExp(
    r'(^|_)(prv|dft|wm|webp|jpeg|jpg|png|heif|avif)(_|$)',
  ).hasMatch(transformation);
  if (!isKnownVariant) return uri.toString();
  return uri.replace(path: uri.path.substring(0, marker)).toString();
}

List<String> mediaImageCandidates(
  MediaItem media,
  SourceId source,
  MediaImageQuality quality,
) {
  final high = normalizeMediaUrl(media.fullImageUrl);
  final preview = normalizeMediaUrl(media.previewImageUrl);
  final values = <String>[
    if (quality == MediaImageQuality.original && source == SourceId.xhs)
      xhsOriginalImageUrl(high),
    if (quality != MediaImageQuality.thumbnail) high,
    preview,
    if (quality == MediaImageQuality.thumbnail) high,
  ];
  final seen = <String>{};
  return values.where((value) => value.isNotEmpty && seen.add(value)).toList();
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
  if (source == SourceId.zhihu) 'Referer': 'https://www.zhihu.com/',
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
    this.fallbackUrls = const <String>[],
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
  final List<String> fallbackUrls;

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
        oldWidget.maxDimension != widget.maxDimension ||
        !listEquals(oldWidget.fallbackUrls, widget.fallbackUrls)) {
      _startLoad();
    }
  }

  void _startLoad({bool evict = false}) {
    _lastError = null;
    final uris = _candidateUris(preferHttps: true);
    if (uris.isEmpty ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      _nativeBytes = null;
      return;
    }
    final source = widget.source;
    final maxDimension = widget.maxDimension;
    final original = _candidateUris(preferHttps: false);
    final key = '${source.id}:$maxDimension:${uris.join('|')}';
    if (evict) _NativeImageCache.evict(key);
    _nativeBytes = _NativeImageCache.load(
      key,
      () => _loadNativeWithFallback(uris, original, source, maxDimension),
    );
  }

  List<Uri> _candidateUris({required bool preferHttps}) {
    final seen = <String>{};
    return <String>[widget.url, ...widget.fallbackUrls]
        .map((value) => mediaUri(value, preferHttps: preferHttps))
        .whereType<Uri>()
        .where((uri) => seen.add(uri.toString()))
        .toList();
  }

  Future<Uint8List> _loadNativeWithFallback(
    List<Uri> preferred,
    List<Uri> original,
    SourceId source,
    int maxDimension,
  ) async {
    final attempts = <({Uri uri, Map<String, String> headers})>[
      for (final uri
          in preferred) ...<({Uri uri, Map<String, String> headers})>[
        (uri: uri, headers: mediaRequestHeaders(source)),
        (uri: uri, headers: const <String, String>{}),
      ],
      for (final uri in original)
        if (!preferred.contains(uri))
          (uri: uri, headers: mediaRequestHeaders(source)),
    ];
    Object? lastError;
    for (final attempt in attempts) {
      try {
        return await MixsocialCore.fetchImage(
          attempt.uri.toString(),
          headers: attempt.headers,
          maxDimension: maxDimension,
        );
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('媒体加载失败');
  }

  @override
  Widget build(BuildContext context) {
    final uris = _candidateUris(preferHttps: true);
    if (uris.isEmpty) {
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
            return _networkFallback(uris);
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
    return _networkFallback(uris);
  }

  Widget _networkFallback(List<Uri> uris, [int index = 0]) => Image.network(
    uris[index].toString(),
    headers: mediaRequestHeaders(widget.source),
    width: widget.width,
    height: widget.height,
    fit: widget.fit,
    alignment: widget.alignment,
    filterQuality: widget.filterQuality,
    gaplessPlayback: true,
    semanticLabel: widget.semanticLabel,
    errorBuilder: (context, error, stackTrace) {
      if (index + 1 < uris.length) return _networkFallback(uris, index + 1);
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

class ProgressiveSourceNetworkImage extends StatelessWidget {
  const ProgressiveSourceNetworkImage({
    super.key,
    required this.media,
    required this.source,
    required this.quality,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.errorBuilder,
    this.filterQuality = FilterQuality.high,
    required this.maxDimension,
    this.previewMaxDimension = 960,
    this.semanticLabel,
  });

  final MediaItem media;
  final SourceId source;
  final MediaImageQuality quality;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageErrorWidgetBuilder? errorBuilder;
  final FilterQuality filterQuality;
  final int maxDimension;
  final int previewMaxDimension;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final candidates = mediaImageCandidates(media, source, quality);
    if (candidates.isEmpty) {
      return errorBuilder?.call(
            context,
            StateError('无可用的媒体地址'),
            StackTrace.current,
          ) ??
          const SizedBox.shrink();
    }
    final preview = mediaImageCandidates(
      media,
      source,
      MediaImageQuality.thumbnail,
    ).firstOrNull;
    final primary = candidates.first;
    if (preview == null || preview == primary) {
      return SourceNetworkImage(
        url: primary,
        fallbackUrls: candidates.skip(1).toList(),
        source: source,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        errorBuilder: errorBuilder,
        filterQuality: filterQuality,
        maxDimension: maxDimension,
        semanticLabel: semanticLabel,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        SourceNetworkImage(
          url: preview,
          source: source,
          width: width,
          height: height,
          fit: fit,
          alignment: alignment,
          errorBuilder: errorBuilder,
          maxDimension: previewMaxDimension,
          semanticLabel: semanticLabel,
        ),
        SourceNetworkImage(
          url: primary,
          fallbackUrls: candidates.skip(1).toList(),
          source: source,
          width: width,
          height: height,
          fit: fit,
          alignment: alignment,
          loadingBuilder: (_, _, _) => const SizedBox.shrink(),
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
          filterQuality: filterQuality,
          maxDimension: maxDimension,
          semanticLabel: semanticLabel,
        ),
      ],
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
  static int _generation = 0;

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
      final generation = _generation;
      try {
        final value = await loader();
        if (generation == _generation) _put(key, value);
        return value;
      } finally {
        if (generation == _generation) _pending.remove(key);
      }
    });
  }

  static void clear() {
    _generation++;
    _values.clear();
    _pending.clear();
    _currentBytes = 0;
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

/// Counts decoded/native in-memory images only; does not touch sessions or data.
class MediaCacheInfo {
  static int get nativeBytes => _NativeImageCache._currentBytes;
  static int get flutterBytes =>
      PaintingBinding.instance.imageCache.currentSizeBytes;
  static int get nativeEntries => _NativeImageCache._values.length;

  static void clearMemory() {
    _NativeImageCache.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}
