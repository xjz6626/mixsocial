import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'home_screen.dart';

class MixsocialApp extends StatefulWidget {
  const MixsocialApp({super.key, this.controller});

  final MixsocialController? controller;

  @override
  State<MixsocialApp> createState() => _MixsocialAppState();
}

class _MixsocialAppState extends State<MixsocialApp> {
  late Future<MixsocialController> _controller = _createController();

  Future<MixsocialController> _createController() async {
    final controller = widget.controller ?? await MixsocialController.create();
    if (controller.items.isEmpty) {
      await controller.refresh();
    } else {
      unawaited(controller.refresh());
    }
    return controller;
  }

  void _retry() {
    setState(() => _controller = _createController());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MixsocialController>(
      future: _controller,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final controller = snapshot.requireData;
          return ValueListenableBuilder<AppThemePreference>(
            valueListenable: controller.themePreferenceNotifier,
            child: HomeScreen(controller: controller),
            builder:
                (
                  BuildContext context,
                  AppThemePreference preference,
                  Widget? child,
                ) =>
                    _materialApp(themeMode: preference.themeMode, home: child!),
          );
        }
        if (snapshot.hasError) {
          return _materialApp(
            home: _StartupFailure(
              message: snapshot.error.toString(),
              onRetry: _retry,
            ),
          );
        }
        return _materialApp(home: const _StartupProgress());
      },
    );
  }

  Widget _materialApp({
    required Widget home,
    ThemeMode themeMode = ThemeMode.system,
  }) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mixsocial',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: themeMode,
      themeAnimationDuration: const Duration(milliseconds: 280),
      themeAnimationCurve: Curves.easeOutCubic,
      home: home,
    );
  }
}

class _StartupProgress extends StatelessWidget {
  const _StartupProgress();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: AppLoadingView(title: '正在启动 Mixsocial', message: '正在恢复设置并连接内容源'),
      ),
    );
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: AppStateView(
          icon: Icons.cloud_off_outlined,
          iconColor: colors.error,
          title: '移动核心初始化失败',
          message: message,
          actionLabel: '重新连接',
          onAction: onRetry,
        ),
      ),
    );
  }
}
