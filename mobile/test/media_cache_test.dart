import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/media_cache_screen.dart';
import 'package:mixsocial_mobile/src/media_tools.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/network_media.dart';

void main() {
  testWidgets(
    'clearing memory prevents an old pending download repopulating cache',
    (tester) async {
      MediaCacheInfo.clearMemory();
      const core = MethodChannel('mixsocial/core');
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final pending = Completer<Uint8List>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(core, (_) => pending.future);
      addTearDown(() {
        messenger.setMockMethodCallHandler(core, null);
        MediaCacheInfo.clearMemory();
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: SourceNetworkImage(
            url: 'https://sns-webpic.xhscdn.com/cache-pending.png',
            source: SourceId.xhs,
          ),
        ),
      );
      expect(MediaCacheInfo.nativeBytes, 0);
      MediaCacheInfo.clearMemory();
      pending.complete(bytes);
      await tester.pumpAndSettle();
      expect(MediaCacheInfo.nativeBytes, 0);
      expect(MediaCacheInfo.nativeEntries, 0);
    },
  );

  testWidgets(
    'cache cleanup requires confirmation and only calls owned cache method',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(MediaTools.channel, (call) async {
        methods.add(call.method);
        return call.method == 'cacheBytes' ? 1024 : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(MediaTools.channel, null),
      );
      await tester.pumpWidget(const MaterialApp(home: MediaCacheScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理图片缓存'));
      await tester.pumpAndSettle();
      expect(methods, ['cacheBytes']);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(methods, ['cacheBytes']);
      await tester.tap(find.text('清理图片缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理'));
      await tester.pumpAndSettle();
      expect(methods, ['cacheBytes', 'clearCache', 'cacheBytes']);
      expect(find.text('图片缓存已清理'), findsOneWidget);
    },
  );
}
