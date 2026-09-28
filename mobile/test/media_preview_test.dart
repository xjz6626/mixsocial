import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/detail_screen.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/network_media.dart';

void main() {
  testWidgets('gallery swipes pages and saves or shares the selected image', (
    WidgetTester tester,
  ) async {
    const core = MethodChannel('mixsocial/core');
    const mediaChannel = MethodChannel('mixsocial/media_tools');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(core, (_) async => bytes);
    messenger.setMockMethodCallHandler(mediaChannel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(core, null);
      messenger.setMockMethodCallHandler(mediaChannel, null);
    });
    const first = MediaItem(
      kind: 'image',
      url: 'https://sns-webpic.xhscdn.com/gallery-first.jpg',
    );
    const second = MediaItem(
      kind: 'image',
      url: 'https://sns-webpic.xhscdn.com/gallery-second.jpg',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaPreviewScreen(
          source: SourceId.xhs,
          media: first,
          mediaItems: [first, second],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-650, 0));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    await tester.tap(find.byTooltip('保存图片'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'saveImage');
    expect((calls.single.arguments as Map)['urls'], [second.url]);
    await tester.longPress(
      find.byKey(const Key('media-preview-interactive-viewer')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享图片'));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'shareImage');
    expect((calls.last.arguments as Map)['urls'], [second.url]);
  });

  testWidgets('media preview owns a full zoomable viewport and can reset', (
    WidgetTester tester,
  ) async {
    const channel = MethodChannel('mixsocial/core');
    final imageBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => imageBytes);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaPreviewScreen(
          source: SourceId.xhs,
          media: MediaItem(
            kind: 'image',
            url: 'https://example.invalid/image.jpg',
            width: 1600,
            height: 900,
          ),
        ),
      ),
    );

    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const Key('media-preview-interactive-viewer')),
    );
    final image = tester.widget<ProgressiveSourceNetworkImage>(
      find.byType(ProgressiveSourceNetworkImage),
    );
    expect(viewer.constrained, isFalse);
    expect(viewer.minScale, 1);
    expect(viewer.maxScale, 8);
    expect(viewer.panEnabled, isTrue);
    expect(viewer.scaleEnabled, isTrue);
    expect(image.quality, MediaImageQuality.original);
    expect(image.maxDimension, 4096);

    final transformation = viewer.transformationController!;
    transformation.value = Matrix4.diagonal3Values(3, 3, 1);
    expect(transformation.value.getMaxScaleOnAxis(), 3);

    await tester.tap(find.byTooltip('复原图片'));
    await tester.pump();
    expect(transformation.value, Matrix4.identity());
  });
}
