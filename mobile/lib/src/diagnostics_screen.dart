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
          const Text(
            '记录本次运行最近50条错误和100条加载耗时；仅含来源、批次、耗时和条数，不记录搜索词、Cookie、正文或链接。重启后清空。',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed:
                    sourceDiagnostics.events.isEmpty &&
                        sourceDiagnostics.loads.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: sourceDiagnostics.exportText()),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制脱敏诊断')),
                          );
                        }
                      },
                icon: const Icon(Icons.copy),
                label: const Text('复制脱敏诊断'),
              ),
              TextButton(
                onPressed:
                    sourceDiagnostics.events.isEmpty &&
                        sourceDiagnostics.loads.isEmpty
                    ? null
                    : sourceDiagnostics.clear,
                child: const Text('清空诊断'),
              ),
            ],
          ),
          for (final event
              in sourceDiagnostics.loads
                  .where((event) => event.phase != 'start')
                  .take(12))
            ListTile(
              dense: true,
              title: Text(
                '第 ${event.batch} 批 · ${event.source.label} · ${event.elapsedMilliseconds} ms',
              ),
              subtitle: Text(
                '${event.phase} · ${event.itemCount} 条 · ${event.at.toLocal()}',
              ),
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
