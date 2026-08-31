import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/design_system.dart';

void main() {
  test('light and dark themes share the same Material 3 design language', () {
    final light = buildAppTheme(Brightness.light);
    final dark = buildAppTheme(Brightness.dark);

    expect(light.useMaterial3, isTrue);
    expect(dark.useMaterial3, isTrue);
    expect(light.navigationBarTheme.height, 72);
    expect(dark.navigationRailTheme.minWidth, 80);
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
  });

  test('responsive rules select phone, tablet, and wide layouts', () {
    expect(navigationLayoutForWidth(412), AppNavigationLayout.bottomBar);
    expect(navigationLayoutForWidth(900), AppNavigationLayout.rail);
    expect(navigationLayoutForWidth(1280), AppNavigationLayout.extendedRail);
    expect(feedColumnCountForWidth(600), 2);
    expect(feedColumnCountForWidth(900), 3);
    expect(feedColumnCountForWidth(1400), 4);
  });

  test('theme preferences map to the matching Flutter theme modes', () {
    expect(AppThemePreference.system.themeMode, ThemeMode.system);
    expect(AppThemePreference.light.themeMode, ThemeMode.light);
    expect(AppThemePreference.dark.themeMode, ThemeMode.dark);
  });

  testWidgets('state view explains the state and exposes recovery action', (
    WidgetTester tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: AppStateView(
            icon: Icons.cloud_off_outlined,
            title: '内容加载失败',
            message: '请检查网络连接',
            actionLabel: '重新加载',
            onAction: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('内容加载失败'), findsOneWidget);
    expect(find.text('请检查网络连接'), findsOneWidget);
    expect(find.bySemanticsLabel('内容加载失败。请检查网络连接'), findsOneWidget);

    await tester.tap(find.text('重新加载'));
    expect(retried, isTrue);
  });

  testWidgets('loading view announces progress accessibly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: const Scaffold(
          body: AppLoadingView(title: '正在同步', message: '正在读取推荐内容'),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('正在同步。正在读取推荐内容'), findsOneWidget);
  });
}
