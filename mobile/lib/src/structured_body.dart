import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'models.dart';
import 'network_media.dart';
import 'media_tools.dart';
import 'reading_preferences.dart';

class ReadingBlock {
  const ReadingBlock(this.kind, {this.text = '', this.url = '', this.media});
  final String kind;
  final String text;
  final String url;
  final MediaItem? media;
}

/// Convert HTML to inert native reading blocks. No DOM is executed or embedded.
List<ReadingBlock> parseReadingBlocks(String value) {
  if (value.length > 2 * 1024 * 1024) return const [];
  final blocks = <ReadingBlock>[];
  final text = StringBuffer();
  void flush() {
    final content = text.toString().trim();
    if (content.isNotEmpty) blocks.add(ReadingBlock('text', text: content));
    text.clear();
  }

  void visit(dom.Node node) {
    if (node is dom.Text) {
      text.write(node.data);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName ?? '';
    if (const {
      'script',
      'style',
      'iframe',
      'object',
      'form',
      'noscript',
    }.contains(tag)) {
      return;
    }
    if (tag == 'img') {
      flush();
      final raw =
          node.attributes['data-original'] ??
          node.attributes['data-actualsrc'] ??
          node.attributes['data-src'] ??
          node.attributes['src'] ??
          '';
      final url = mediaUri(raw, preferHttps: true);
      if (url != null) {
        blocks.add(
          ReadingBlock(
            'image',
            media: MediaItem(
              kind: 'image',
              url: url.toString(),
              width:
                  int.tryParse(
                    node.attributes['data-rawwidth'] ??
                        node.attributes['width'] ??
                        '',
                  ) ??
                  0,
              height:
                  int.tryParse(
                    node.attributes['data-rawheight'] ??
                        node.attributes['height'] ??
                        '',
                  ) ??
                  0,
            ),
          ),
        );
      }
      return;
    }
    if (tag == 'a') {
      flush();
      for (final image in node.querySelectorAll('img')) {
        visit(image);
      }
      var uri = Uri.tryParse(node.attributes['href'] ?? '');
      if (uri?.host == 'link.zhihu.com') {
        uri = Uri.tryParse(uri!.queryParameters['target'] ?? '');
      }
      if (uri != null &&
          const {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        blocks.add(
          ReadingBlock('link', text: node.text.trim(), url: uri.toString()),
        );
      } else {
        text.write(node.text);
      }
      return;
    }
    if (tag == 'pre' ||
        tag == 'blockquote' ||
        RegExp(r'^h[1-6]$').hasMatch(tag)) {
      flush();
      // Preserve embedded images/links in quotes instead of flattening them.
      if (tag == 'blockquote' && node.querySelector('img, a') != null) {
        for (final child in node.nodes) {
          visit(child);
        }
        flush();
      } else {
        blocks.add(
          ReadingBlock(
            tag == 'pre'
                ? 'code'
                : tag == 'blockquote'
                ? 'quote'
                : 'heading',
            text: node.text.trim(),
          ),
        );
      }
      return;
    }
    if (tag == 'br') {
      text.write('\n');
      return;
    }
    final block = const {
      'p',
      'div',
      'li',
      'figure',
      'figcaption',
      'tr',
    }.contains(tag);
    if (block) flush();
    if (tag == 'li') text.write('• ');
    for (final child in node.nodes) {
      visit(child);
    }
    if (tag == 'td' || tag == 'th') text.write('  ');
    if (block) flush();
  }

  for (final node in html.parseFragment(value).nodes) {
    visit(node);
  }
  flush();
  return blocks;
}

class StructuredBody extends StatelessWidget {
  const StructuredBody({
    super.key,
    required this.content,
    required this.source,
    required this.preferences,
    required this.onImage,
    this.showImages = true,
  });
  final String content;
  final SourceId source;
  final ReadingPreferences preferences;
  final ValueChanged<MediaItem> onImage;
  final bool showImages;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(
      fontSize: preferences.fontSize,
      height: preferences.lineHeight,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final block in parseReadingBlocks(
          content,
        ).where((block) => showImages || block.kind != 'image'))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: switch (block.kind) {
              'image' => GestureDetector(
                onTap: () => onImage(block.media!),
                child: AspectRatio(
                  aspectRatio: block.media!.aspectRatio.clamp(.2, 3),
                  child: ProgressiveSourceNetworkImage(
                    media: block.media!,
                    source: source,
                    quality: MediaImageQuality.detail,
                    maxDimension: 2560,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              'link' => TextButton.icon(
                onPressed: () async {
                  try {
                    await MediaTools.openUrl(block.url);
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('未能打开链接')));
                    }
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(block.text.isEmpty ? block.url : block.text),
              ),
              'heading' => SelectableText(
                block.text,
                style: style?.copyWith(
                  fontSize: preferences.fontSize + 3,
                  fontWeight: FontWeight.bold,
                ),
              ),
              'code' => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  block.text,
                  style: style?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              'quote' => Container(
                padding: const EdgeInsets.only(left: 12),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      width: 3,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: SelectableText(block.text, style: style),
              ),
              _ => SelectableText(block.text, style: style),
            },
          ),
      ],
    );
  }
}
