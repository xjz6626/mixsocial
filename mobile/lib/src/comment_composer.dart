import 'dart:async';

import 'package:flutter/material.dart';

import 'comment_drafts.dart';
import 'source_diagnostics.dart';

Future<bool> showCommentComposer(
  BuildContext context, {
  required String title,
  required String hint,
  required String draftKey,
  required CommentDraftStore drafts,
  required Future<void> Function(String body) onSend,
  String replyPreview = '',
  bool externalHandoff = false,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _CommentComposer(
        title: title,
        hint: hint,
        draftKey: draftKey,
        drafts: drafts,
        onSend: onSend,
        replyPreview: replyPreview,
        externalHandoff: externalHandoff,
      ),
    ) ??
    false;

class _CommentComposer extends StatefulWidget {
  const _CommentComposer({
    required this.title,
    required this.hint,
    required this.draftKey,
    required this.drafts,
    required this.onSend,
    required this.replyPreview,
    required this.externalHandoff,
  });

  final String title;
  final String hint;
  final String draftKey;
  final CommentDraftStore drafts;
  final Future<void> Function(String) onSend;
  final String replyPreview;
  final bool externalHandoff;

  @override
  State<_CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<_CommentComposer> {
  final _text = TextEditingController();
  bool _loading = true;
  bool _sending = false;
  bool _unconfirmed = false;
  bool _confirmed = false;
  String? _error;
  int _saveGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await widget.drafts.read(widget.draftKey);
      if (!mounted) return;
      _text.text = value?.body ?? '';
      _unconfirmed = value?.unconfirmed ?? false;
    } catch (error) {
      if (mounted) _error = '读取草稿失败：${safeLocalMessage(error)}';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _save() async {
    final generation = ++_saveGeneration;
    try {
      await widget.drafts.save(
        widget.draftKey,
        CommentDraft(body: _text.text, unconfirmed: _unconfirmed),
      );
      return true;
    } catch (error) {
      if (mounted && generation == _saveGeneration) {
        setState(() => _error = '草稿未能保存，请复制正文备份：${safeLocalMessage(error)}');
      }
      return false;
    }
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (_loading || _sending || _unconfirmed || body.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
      // Persist before dispatch: process termination must not allow a silent
      // duplicate post when this draft is reopened.
      _unconfirmed = !widget.externalHandoff;
    });
    if (!await _save()) {
      if (mounted) {
        setState(() {
          _sending = false;
          _unconfirmed = false;
        });
      }
      return;
    }
    try {
      await widget.onSend(body);
      _confirmed = true;
      if (!widget.externalHandoff) {
        try {
          await widget.drafts.clear(widget.draftKey, expectedBody: body);
        } catch (_) {
          // Keep the guard: platform succeeded but local cleanup failed.
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = '${safeSourceMessage(error)}\n正文已保留，请先核对帖子是否已收到这条发言。',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _close() async {
    if (_sending || _loading) return;
    if (await _save() && mounted) Navigator.pop(context, false);
  }

  Future<void> _clear() async {
    if (_sending) return;
    try {
      await widget.drafts.clear(widget.draftKey);
      if (!mounted) return;
      setState(() {
        _text.clear();
        _unconfirmed = false;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '清空草稿失败：${safeLocalMessage(error)}');
    }
  }

  @override
  void dispose() {
    // Each edit is already enqueued. No late write here can resurrect a draft
    // cleared after a confirmed submission.
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_sending,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '保存草稿并关闭',
                    onPressed: _loading || _sending ? null : _close,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (widget.replyPreview.isNotEmpty) ...<Widget>[
                Text(
                  widget.replyPreview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
              ],
              if (_loading) const LinearProgressIndicator(),
              if (widget.externalHandoff)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('此处仅准备草稿。复制后请在贴吧官方网页找到对应楼层，粘贴并手动发送；本机草稿会保留。'),
                ),
              TextField(
                key: const Key('comment-input'),
                controller: _text,
                enabled: !_loading && !_sending && !_confirmed,
                autofocus: true,
                minLines: 3,
                maxLines: 6,
                maxLength: 500,
                onChanged: (_) {
                  setState(() {});
                  unawaited(_save());
                },
                decoration: InputDecoration(
                  hintText: widget.hint,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_unconfirmed && !_sending) ...<Widget>[
                const Text('上次发送未确认。请先关闭此窗口并刷新帖子核对，避免重复发言。'),
                TextButton(
                  onPressed: () {
                    setState(() => _unconfirmed = false);
                    unawaited(_save());
                  },
                  child: const Text('我已核对，确认未发送'),
                ),
              ],
              Row(
                children: <Widget>[
                  TextButton(
                    onPressed: _loading || _sending ? null : _clear,
                    child: const Text('清空草稿'),
                  ),
                  const Spacer(),
                  const Text('草稿仅保存在本机'),
                ],
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      _loading ||
                          _sending ||
                          _unconfirmed ||
                          _text.text.trim().isEmpty
                      ? null
                      : _send,
                  child: Text(
                    _sending
                        ? '处理中，请稍候…'
                        : widget.externalHandoff
                        ? '复制并前往官方页'
                        : '发送',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
