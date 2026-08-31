import 'package:flutter/material.dart';

import 'models.dart';
import 'network_media.dart';

class FeedMediaPreview extends StatelessWidget {
  const FeedMediaPreview({
    super.key,
    required this.item,
    this.borderRadius = BorderRadius.zero,
    this.maxDimension = 960,
  });

  final FeedItem item;
  final BorderRadius borderRadius;
  final int maxDimension;

  @override
  Widget build(BuildContext context) {
    final media = item.media.firstOrNull;
    final ratio = (media?.aspectRatio ?? 4 / 3).clamp(0.62, 1.8);
    return ClipRRect(
      borderRadius: borderRadius,
      child: AspectRatio(
        aspectRatio: ratio,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (media != null && media.displayUrl.isNotEmpty)
                SourceNetworkImage(
                  url: media.displayUrl,
                  source: item.ref.source,
                  fit: BoxFit.cover,
                  maxDimension: maxDimension,
                  semanticLabel: media.kind == 'video' ? '视频预览' : '图片预览',
                  errorBuilder: (context, error, stackTrace) =>
                      const _MediaFallback(),
                )
              else
                const _MediaFallback(),
              if (media?.kind == 'video')
                const Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(9),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 8,
                top: 8,
                child: SourceBadge(source: item.ref.source),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.source});

  final SourceId source;

  @override
  Widget build(BuildContext context) {
    final colors = switch (source) {
      SourceId.xhs => (const Color(0xffe9274f), Colors.white),
      SourceId.tieba => (const Color(0xff3478f6), Colors.white),
      SourceId.all => (
        Theme.of(context).colorScheme.primaryContainer,
        Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.$1,
        borderRadius: BorderRadius.circular(7),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Colors.black12, blurRadius: 3),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          source.label,
          style: TextStyle(
            color: colors.$2,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class AuthorAvatar extends StatelessWidget {
  const AuthorAvatar({super.key, required this.author, this.radius = 12});

  final Author author;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = Text(
      author.name.isEmpty ? '?' : author.name.characters.first,
      style: TextStyle(fontSize: radius * .9),
    );
    if (author.avatar.isEmpty) {
      return CircleAvatar(radius: radius, child: fallback);
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ClipOval(
        child: SourceNetworkImage(
          url: author.avatar,
          source: author.ref.source,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Center(child: fallback),
        ),
      ),
    );
  }
}

class CompactStat extends StatelessWidget {
  const CompactStat({super.key, required this.icon, required this.value});

  final IconData icon;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: 15,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 3),
        Text(
          compactCount(value),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}

String compactCount(int value) {
  if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
  if (value >= 10000) {
    return '${(value / 10000).toStringAsFixed(value >= 100000 ? 0 : 1)}万';
  }
  return value.toString();
}

class _MediaFallback extends StatelessWidget {
  const _MediaFallback();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.image_not_supported_outlined,
        color: Theme.of(context).colorScheme.outline,
        size: 34,
      ),
    );
  }
}
