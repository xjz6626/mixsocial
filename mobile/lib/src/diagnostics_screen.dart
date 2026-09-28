import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'source_diagnostics.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('连接诊断')),
    body: AnimatedBuilder(
      animation: sourceDiagnostics,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text('仅记录本次运行的最近50条错误类别，不记录Cookie、BDUSS、帖子正文、链接或原始响应。重启后清空。'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: sourceDiagnostics.events.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: sourceDiagnostics.exportText()),
                        );
                        if (context.mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制脱敏诊断')),
                          );
                      },
                icon: const Icon(Icons.copy),
                label: const Text('复制脱敏诊断'),
              ),
              TextButton(
                onPressed: sourceDiagnostics.events.isEmpty
                    ? null
                    : sourceDiagnostics.clear,
                child: const Text('清空诊断'),
              ),
            ],
          ),
          if (sourceDiagnostics.events.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('当前没有记录到连接错误'),
            ),
          for (final event in sourceDiagnostics.events)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text('${event.source.label} · ${event.operation}'),
              subtitle: Text('${event.failure.message}\n${event.at.toLocal()}'),
            ),
        ],
      ),
    ),
  );
}
