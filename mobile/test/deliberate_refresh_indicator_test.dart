import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/deliberate_refresh_indicator.dart';

void main() {
  testWidgets('requires a deliberate pull and release to refresh', (
    WidgetTester tester,
  ) async {
    final controller = ScrollController();
    var refreshCount = 0;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeliberateRefreshIndicator(
            controller: controller,
            onRefresh: () async => refreshCount++,
            child: ListView(
              key: const Key('feed'),
              controller: controller,
              physics: const AlwaysScrollableScrollPhysics(),
              children: const <Widget>[SizedBox(height: 900)],
            ),
          ),
        ),
      ),
    );

    final origin = tester.getCenter(find.byKey(const Key('feed')));
    final shortPull = await tester.startGesture(origin);
    await shortPull.moveBy(const Offset(0, 55));
    await shortPull.up();
    await tester.pumpAndSettle();
    expect(refreshCount, 0);

    final longPull = await tester.startGesture(origin);
    for (var index = 0; index < 17; index++) {
      await longPull.moveBy(const Offset(0, 7));
    }
    await longPull.moveBy(const Offset(0, 1));
    await tester.pump();
    expect(find.text('松开刷新'), findsOneWidget);
    await longPull.up();
    await tester.pumpAndSettle();
    expect(refreshCount, 1);
  });

  testWidgets('does not refresh when a gesture starts away from the top', (
    WidgetTester tester,
  ) async {
    final controller = ScrollController(initialScrollOffset: 300);
    var refreshCount = 0;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeliberateRefreshIndicator(
            controller: controller,
            onRefresh: () async => refreshCount++,
            child: ListView(
              controller: controller,
              children: const <Widget>[SizedBox(height: 1200)],
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(const Offset(200, 250));
    await gesture.moveBy(const Offset(0, 180));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(refreshCount, 0);
  });
}
