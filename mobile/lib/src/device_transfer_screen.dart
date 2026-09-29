import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'device_transfer.dart';
import 'device_transfer_pending.dart';
import 'device_transfer_service.dart';

class DeviceTransferScreen extends StatefulWidget {
  const DeviceTransferScreen({super.key, required this.controller});

  final MixsocialController controller;

  @override
  State<DeviceTransferScreen> createState() => _DeviceTransferScreenState();
}

class _DeviceTransferScreenState extends State<DeviceTransferScreen>
    with WidgetsBindingObserver {
  late final DeviceTransferService _service = DeviceTransferService(
    widget.controller,
  );
  late final DeviceTransferPendingStore _pendingStore =
      DeviceTransferPendingStore();
  DeviceTransferPayload? _payload;
  DeviceTransferSender? _sender;
  PendingDeviceTransfer? _pending;
  Timer? _clock;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPending());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_closeSenderWhenBackgrounded());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    final sender = _sender;
    if (sender != null) {
      sender.state.removeListener(_senderChanged);
      unawaited(sender.close());
    }
    super.dispose();
  }

  Future<void> _loadPending() async {
    final pending = await _pendingStore.load();
    if (!mounted || pending == null) return;
    setState(() {
      _pending = pending;
      _message = '检测到上次未完成的迁移，可以从安全暂存继续。';
      _messageIsError = false;
    });
  }

  Future<void> _closeSenderWhenBackgrounded() async {
    final sender = _sender;
    if (sender == null) return;
    sender.state.removeListener(_senderChanged);
    _clock?.cancel();
    _clock = null;
    _sender = null;
    _payload = null;
    await sender.close();
    if (!mounted) return;
    setState(() {
      _message = '应用离开前台，迁移二维码已为安全起见关闭，请重新生成。';
      _messageIsError = false;
    });
  }

  void _senderChanged() {
    if (!mounted) return;
    final state = _sender?.state.value;
    setState(() {
      switch (state) {
        case DeviceTransferSenderState.sent:
          _message = '另一台设备已安全接收数据。本二维码已失效。';
          _messageIsError = false;
        case DeviceTransferSenderState.expired:
          _message = '二维码已过期，请重新生成。';
          _messageIsError = true;
        case DeviceTransferSenderState.failed:
          _message = '传输中断，请保持两台设备在同一 Wi-Fi 后重试。';
          _messageIsError = true;
        case DeviceTransferSenderState.waiting ||
            DeviceTransferSenderState.cancelled ||
            null:
          break;
      }
    });
  }

  Future<void> _startSending() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final old = _sender;
      if (old != null) {
        old.state.removeListener(_senderChanged);
        await old.close();
      }
      final payload = await _service.createPayload();
      final sender = await DeviceTransferSender.start(payload);
      sender.state.addListener(_senderChanged);
      _clock?.cancel();
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      if (!mounted) {
        await sender.close();
        return;
      }
      setState(() {
        _payload = payload;
        _sender = sender;
        _message = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = _friendlyError(error);
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanAndImport() async {
    if (_busy) return;
    try {
      if (!mounted) return;
      final scanned = await Navigator.push<_ScannedTransfer>(
        context,
        MaterialPageRoute<_ScannedTransfer>(
          builder: (_) => const _DeviceTransferScannerScreen(),
        ),
      );
      if (scanned == null || !mounted) return;
      final payload = scanned.payload;
      final confirmed = await _confirmImport(payload, scanned.verificationCode);
      if (confirmed != true || !mounted) return;
      await _runImport(
        payload,
        scanned.verificationCode,
        stageBeforeImport: true,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = _friendlyError(error);
          _messageIsError = true;
        });
      }
    }
  }

  Future<void> _resumePending() async {
    final pending = _pending;
    if (pending == null || _busy) return;
    final confirmed = await _confirmImport(
      pending.payload,
      pending.verificationCode,
    );
    if (confirmed != true || !mounted) return;
    await _runImport(
      pending.payload,
      pending.verificationCode,
      stageBeforeImport: false,
    );
  }

  Future<void> _runImport(
    DeviceTransferPayload payload,
    String verificationCode, {
    required bool stageBeforeImport,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = stageBeforeImport ? '正在安全暂存迁移数据…' : '正在继续上次迁移…';
      _messageIsError = false;
    });
    try {
      if (stageBeforeImport) {
        await _pendingStore.stage(payload, verificationCode);
        _pending = PendingDeviceTransfer(
          payload: payload,
          verificationCode: verificationCode,
        );
      }
      if (mounted) setState(() => _message = '正在合并数据并恢复账号…');
      final result = await _service.importPayload(payload);
      await _pendingStore.clear();
      if (!mounted) return;
      unawaited(HapticFeedback.heavyImpact());
      setState(() {
        _pending = null;
        final accounts = result.accounts.isEmpty
            ? '没有账号凭据'
            : '已恢复 ${result.accounts.join('、')}';
        _message =
            '迁移完成：已处理 ${result.localItems} 条本地内容，$accounts。'
            '${result.warnings.isEmpty ? '' : '\n${result.warnings.join('\n')}'}';
        _messageIsError = result.warnings.isNotEmpty;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = '${_friendlyError(error)}\n已完成的步骤不会丢失，可稍后继续迁移。';
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmImport(
    DeviceTransferPayload payload,
    String verificationCode,
  ) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.move_to_inbox_outlined),
      title: const Text('导入这台设备？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SummaryLine(
            icon: Icons.verified_user_outlined,
            label: '校验码 $verificationCode（应与旧设备一致）',
          ),
          _SummaryLine(
            icon: Icons.person_outline,
            label: payload.accountLabels.isEmpty
                ? '不含账号登录状态'
                : '账号：${payload.accountLabels.join('、')}',
          ),
          _SummaryLine(
            icon: Icons.bookmarks_outlined,
            label:
                '${payload.library.entries.length} 条收藏/稍后阅读，${payload.history.entries.length} 条历史',
          ),
          _SummaryLine(
            icon: Icons.tune,
            label: '${payload.readingStates.length} 条阅读进度，以及外观、过滤和搜索设置',
          ),
          const SizedBox(height: AppSpacing.md),
          const Text('本地内容会合并；同平台登录状态会替换为旧设备的账号。'),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.download_done),
          label: const Text('导入全部'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final sender = _sender;
    final payload = _payload;
    return Scaffold(
      appBar: AppBar(title: const Text('设备迁移')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _SecurityBanner(),
                  const SizedBox(height: AppSpacing.lg),
                  if (_pending case final pending?) ...<Widget>[
                    _PendingTransferCard(
                      pending: pending,
                      busy: _busy,
                      onResume: _resumePending,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  if (sender != null && payload != null)
                    _SenderCard(
                      sender: sender,
                      payload: payload,
                      onRegenerate: _startSending,
                    )
                  else
                    _TransferChoiceCard(
                      busy: _busy,
                      onSend: _startSending,
                      onReceive: _scanAndImport,
                    ),
                  if (sender != null && payload != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.md),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _scanAndImport,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('改为接收数据'),
                    ),
                  ],
                  if (_busy) ...<Widget>[
                    const SizedBox(height: AppSpacing.lg),
                    const LinearProgressIndicator(minHeight: 3),
                  ],
                  if (_message case final message?) ...<Widget>[
                    const SizedBox(height: AppSpacing.lg),
                    _StatusCard(message: message, error: _messageIsError),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  const _HowItWorks(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingTransferCard extends StatelessWidget {
  const _PendingTransferCard({
    required this.pending,
    required this.busy,
    required this.onResume,
  });

  final PendingDeviceTransfer pending;
  final bool busy;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: <Widget>[
            Icon(Icons.restore, color: colors.onTertiaryContainer),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '继续上次迁移',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '校验码 ${pending.verificationCode} · '
                    '${pending.payload.localItemCount} 条本地内容已加密暂存',
                    style: TextStyle(color: colors.onTertiaryContainer),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            FilledButton(
              onPressed: busy ? null : onResume,
              child: const Text('继续'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferChoiceCard extends StatelessWidget {
  const _TransferChoiceCard({
    required this.busy,
    required this.onSend,
    required this.onReceive,
  });

  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('选择这台设备的角色', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            key: const Key('device-transfer-send'),
            onPressed: busy ? null : onSend,
            icon: const Icon(Icons.qr_code_2),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('这是旧设备 · 生成二维码'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            key: const Key('device-transfer-receive'),
            onPressed: busy ? null : onReceive,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('这是新设备 · 扫码接收'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SecurityBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.lock_outline, color: colors.onPrimaryContainer),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '端到端加密直传',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '数据不经过云端，二维码不包含明文 Cookie；连接仅使用一次，并在 2 分钟后失效。',
                    style: TextStyle(color: colors.onPrimaryContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SenderCard extends StatelessWidget {
  const _SenderCard({
    required this.sender,
    required this.payload,
    required this.onRegenerate,
  });

  final DeviceTransferSender sender;
  final DeviceTransferPayload payload;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final remaining = sender.expiresAt
        .difference(DateTime.now())
        .inSeconds
        .clamp(0, 120);
    final waiting = sender.state.value == DeviceTransferSenderState.waiting;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          children: <Widget>[
            Text(
              waiting ? '用新设备扫描' : '此二维码已失效',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              waiting ? '请保持两台设备连接同一 Wi-Fi' : '如需再次迁移，请生成新二维码',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            Opacity(
              opacity: waiting ? 1 : 0.3,
              child: Semantics(
                image: true,
                label: waiting ? '一次性设备迁移二维码，请用新设备扫描' : '已经失效的设备迁移二维码',
                child: ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                    ),
                    child: QrImageView(
                      data: sender.ticket.encode(),
                      size: 248,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Colors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                Chip(
                  avatar: const Icon(Icons.timer_outlined, size: 18),
                  label: Text(waiting ? '剩余 $remaining 秒' : '已关闭'),
                ),
                Chip(
                  avatar: const Icon(Icons.pin_outlined, size: 18),
                  label: Text('校验码 ${sender.ticket.verificationCode}'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '${payload.accountLabels.length} 个账号 · '
              '${payload.library.entries.length} 条收藏/稍后阅读 · '
              '${payload.history.entries.length} 条历史',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!waiting) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              FilledButton.tonalIcon(
                onPressed: onRegenerate,
                icon: const Icon(Icons.refresh),
                label: const Text('重新生成'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.message, required this.error});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = error ? colors.errorContainer : colors.secondaryContainer;
    final foreground = error
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              error ? Icons.info_outline : Icons.check_circle_outline,
              color: foreground,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(message, style: TextStyle(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('迁移内容', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: AppSpacing.md),
      const _SummaryLine(icon: Icons.key_outlined, label: '小红书、贴吧、知乎登录状态'),
      const _SummaryLine(
        icon: Icons.collections_bookmark_outlined,
        label: '本地收藏、稍后阅读、收藏夹、标签和浏览历史',
      ),
      const _SummaryLine(
        icon: Icons.auto_awesome_outlined,
        label: '主题、布局、内容过滤、搜索记录和阅读进度',
      ),
      const SizedBox(height: AppSpacing.sm),
      Text(
        '请只扫描自己设备上实时显示的二维码，不要转发截图。迁移不会删除旧设备的数据。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 20),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: Text(label)),
      ],
    ),
  );
}

class _DeviceTransferScannerScreen extends StatefulWidget {
  const _DeviceTransferScannerScreen();

  @override
  State<_DeviceTransferScannerScreen> createState() =>
      _DeviceTransferScannerScreenState();
}

class _DeviceTransferScannerScreenState
    extends State<_DeviceTransferScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _processing = false;
  String? _error;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  Future<void> _detected(BarcodeCapture capture) async {
    if (_processing) return;
    final value = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (value == null) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    await _controller.stop();
    try {
      final ticket = DeviceTransferTicket.decode(value);
      final payload = await DeviceTransferSender.receive(ticket);
      if (mounted) {
        Navigator.pop(
          context,
          _ScannedTransfer(payload, ticket.verificationCode),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = _friendlyError(error);
      });
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: const Text('扫描旧设备'),
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      actions: <Widget>[
        IconButton(
          tooltip: '手电筒',
          onPressed: _controller.toggleTorch,
          icon: const Icon(Icons.flashlight_on_outlined),
        ),
      ],
    ),
    body: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        MobileScanner(
          controller: _controller,
          onDetect: _detected,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Text(
                '无法使用相机，请在系统设置中允许相机权限。\n${error.errorDetails?.message ?? ''}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: Center(
            child: Container(
              width: 270,
              height: 270,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(AppRadii.lg),
              ),
            ),
          ),
        ),
        Positioned(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: 48,
          child: SafeArea(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (_processing)
                      const CircularProgressIndicator(color: Colors.white)
                    else
                      const Icon(Icons.qr_code_scanner, color: Colors.white),
                    const SizedBox(height: AppSpacing.sm),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _processing ? '正在建立加密连接…' : _error ?? '将旧设备的迁移二维码放入框内',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _error == null
                              ? Colors.white
                              : Colors.orangeAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ScannedTransfer {
  const _ScannedTransfer(this.payload, this.verificationCode);

  final DeviceTransferPayload payload;
  final String verificationCode;
}

String _friendlyError(Object error) => error is FormatException
    ? error.message
    : error is SocketException
    ? '局域网连接失败，请确认两台设备位于同一 Wi-Fi 后重试'
    : '设备迁移暂时失败，请重试';
