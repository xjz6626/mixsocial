import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/content_link_dialog.dart';
import 'package:mixsocial_mobile/src/models.dart';

void main() {
  testWidgets(
    'never reads clipboard automatically and requires explicit open',
    (tester) async {
      var clipboardReads = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          clipboardReads++;
          return {'text': 'https://tieba.baidu.com/p/42'};
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      ContentRef? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  opened = await showDialog<ContentRef>(
                    context: context,
                    builder: (_) => const ContentLinkDialog(),
                  );
                },
                child: const Text('入口'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('入口'));
      await tester.pumpAndSettle();
      expect(clipboardReads, 0);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '打开'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('从剪贴板粘贴'));
      await tester.pumpAndSettle();
      expect(clipboardReads, 1);
      expect(opened, null);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(opened?.id, '42');
    },
  );

  testWidgets('unsupported incoming text cannot open any destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ContentLinkDialog(initialText: 'https://evil.example/p/42'),
      ),
    );
    expect(find.text('未发现受支持的帖子链接'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '打开'))
          .onPressed,
      isNull,
    );
  });
}
