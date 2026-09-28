import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'content_links.dart';
import 'models.dart';

class ContentLinkDialog extends StatefulWidget {
  const ContentLinkDialog({super.key, this.initialText = ''});
  final String initialText;

  @override
  State<ContentLinkDialog> createState() => _ContentLinkDialogState();
}

class _ContentLinkDialogState extends State<ContentLinkDialog> {
  late final _text = TextEditingController(text: widget.initialText);
  bool _busy = false;
  String? _error;
  Uri? _selected;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    try {
      final value = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      setState(() {
        _text.text = (value?.text ?? '').characters.take(65536).toString();
        _selected = null;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取剪贴板，请手动粘贴');
    }
  }

  Future<void> _open(Uri uri) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ref = await resolveContentLink(uri);
      if (mounted) Navigator.pop<ContentRef>(context, ref);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '未能打开链接，请确认是完整帖子链接；短链接可能需要复制网页中的完整地址');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final links = extractContentLinks(_text.text);
    final selected = links.contains(_selected) ? _selected : links.firstOrNull;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('打开帖子链接'),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('支持贴吧帖子、小红书笔记、xhslink 短链接，以及知乎问题、回答、文章和想法链接。只有确认打开后才会联网，不会自动读取剪贴板。'),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('content-link-input'),
                  controller: _text,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 65536,
                  decoration: const InputDecoration(
                    labelText: '粘贴链接或分享文本',
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() {
                    _selected = null;
                    _error = null;
                  }),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('从剪贴板粘贴'),
                ),
                if (links.length > 1)
                  ...links.map(
                    (uri) => ListTile(
                      dense: true,
                      selected: uri == selected,
                      leading: Icon(
                        uri == selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(
                        '${uri.host}${uri.path}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: _busy
                          ? null
                          : () => setState(() => _selected = uri),
                    ),
                  ),
                if (links.isEmpty && _text.text.isNotEmpty)
                  const Text('未发现受支持的帖子链接'),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy || selected == null ? null : () => _open(selected),
            child: const Text('打开'),
          ),
        ],
      ),
    );
  }
}
