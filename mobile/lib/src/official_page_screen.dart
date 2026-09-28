import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'source_diagnostics.dart';
import 'models.dart';

class OfficialPageScreen extends StatefulWidget {
  const OfficialPageScreen({super.key, required this.load, required this.title, required this.source});
  final Future<WebViewController> Function() load;
  final String title;
  final SourceId source;
  @override
  State<OfficialPageScreen> createState() => _OfficialPageScreenState();
}

class _OfficialPageScreenState extends State<OfficialPageScreen> {
  WebViewController? _controller;
  String? _error;
  bool _loading = false;
  @override
  void initState() { super.initState(); unawaited(_load()); }
  Future<void> _load() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final controller = await widget.load();
      if (mounted) setState(() => _controller = controller);
    } catch (error) {
      sourceDiagnostics.record(widget.source, '官方网页', error);
      if (mounted) setState(() => _error = SourceFailure.from(error).message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title), actions: <Widget>[
      IconButton(tooltip: '刷新网页', onPressed: _controller?.reload, icon: const Icon(Icons.refresh)),
    ]),
    body: _error != null ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
      Padding(padding: const EdgeInsets.all(20), child: Text(_error!)),
      OutlinedButton(onPressed: _load, child: const Text('重试')),
    ])) : _controller == null ? const Center(child: CircularProgressIndicator()) : WebViewWidget(controller: _controller!),
  );
}
