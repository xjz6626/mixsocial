import 'package:flutter/material.dart';

import 'app_controller.dart';
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
    if (controller.items.isEmpty) await controller.refresh();
    return controller;
  }

  void _retry() {
    setState(() => _controller = _createController());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mixsocial',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffef3653),
          brightness: Brightness.light,
          surface: const Color(0xfffffbff),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff8f7fa),
        cardTheme: const CardThemeData(
          clipBehavior: Clip.antiAlias,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      home: FutureBuilder<MixsocialController>(
        future: _controller,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return HomeScreen(controller: snapshot.requireData);
          }
          if (snapshot.hasError) {
            return _StartupFailure(
              message: snapshot.error.toString(),
              onRetry: _retry,
            );
          }
          return const _StartupProgress();
        },
      ),
    );
  }
}

class _StartupProgress extends StatelessWidget {
  const _StartupProgress();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.hub_outlined, size: 44),
            SizedBox(height: 20),
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在连接内容源…'),
          ],
        ),
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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.cloud_off_outlined,
                  size: 52,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  '移动核心初始化失败',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
