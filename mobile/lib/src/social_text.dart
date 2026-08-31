import 'package:flutter/material.dart';

import 'models.dart';

final RegExp _xhsTopicPattern = RegExp(
  r'#([^#\n]{1,48})\[话题\]#|#([\u3400-\u9fffA-Za-z0-9_·-]{1,48})',
  unicode: true,
);

List<String> extractXhsTopics(String value) {
  final topics = <String>{};
  for (final match in _xhsTopicPattern.allMatches(value)) {
    final topic = (match.group(1) ?? match.group(2) ?? '').trim();
    if (topic.isNotEmpty) topics.add(topic);
  }
  return topics.toList(growable: false);
}

class SocialRichText extends StatelessWidget {
  const SocialRichText({
    super.key,
    required this.text,
    required this.source,
    this.style,
    this.leading = const <InlineSpan>[],
    this.onTopicTap,
  });

  final String text;
  final SourceId source;
  final TextStyle? style;
  final List<InlineSpan> leading;
  final ValueChanged<String>? onTopicTap;

  @override
  Widget build(BuildContext context) {
    final normalized = normalizeSocialText(text);
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    if (source != SourceId.xhs) {
      return Text.rich(
        TextSpan(
          style: effectiveStyle,
          children: <InlineSpan>[
            ...leading,
            TextSpan(text: normalized),
          ],
        ),
      );
    }

    final spans = <InlineSpan>[...leading];
    var offset = 0;
    for (final match in _xhsTopicPattern.allMatches(normalized)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: normalized.substring(offset, match.start)));
      }
      final topic = (match.group(1) ?? match.group(2) ?? '').trim();
      if (topic.isEmpty) {
        spans.add(TextSpan(text: match.group(0)));
      } else {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Semantics(
              link: onTopicTap != null,
              label: '话题 $topic',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTopicTap == null ? null : () => onTopicTap!(topic),
                child: Text(
                  '#$topic',
                  style: effectiveStyle.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      offset = match.end;
    }
    if (offset < normalized.length) {
      spans.add(TextSpan(text: normalized.substring(offset)));
    }

    return Text.rich(TextSpan(style: effectiveStyle, children: spans));
  }
}
