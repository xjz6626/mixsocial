import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_core/mixsocial_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixsocial/core');

  test('Zhihu bridge uses source-scoped methods and request IDs', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'zhihu.browse' => '{"items":[]}',
        'zhihu.comments' => '{"comments":[]}',
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await MixsocialCore.configureZhihu(pageSize: 12);
    expect(await MixsocialCore.browseZhihu('hot', 'next'), '{"items":[]}');
    expect(
      await MixsocialCore.zhihuComments('{"id":"42"}', '10'),
      '{"comments":[]}',
    );
    await MixsocialCore.likeZhihu('{"id":"42"}', true);

    expect(calls.map((call) => call.method), <String>[
      'zhihu.configure',
      'zhihu.browse',
      'zhihu.comments',
      'zhihu.like',
    ]);
    expect((calls.first.arguments as Map)['pageSize'], 12);
    for (final call in calls.skip(1)) {
      expect((call.arguments as Map)['requestId'], isNotEmpty);
    }
  });
}
