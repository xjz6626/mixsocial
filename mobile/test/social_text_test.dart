import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/social_text.dart';

void main() {
  test('internal emoticon resource names become readable glyphs', () {
    expect(normalizeSocialText('前面image_emoticon25后面'), '前面😏后面');
    expect(normalizeSocialText('#(image_emoticon25)'), '😏');
    expect(normalizeSocialText('#(滑稽)'), '😏');
    expect(normalizeSocialText('image_emoticon34'), '❤️');
    expect(normalizeSocialText('image_emoticon80'), '💩');
    expect(normalizeSocialText('image_emoticon999'), '[表情]');

    const supportedIds = <int>[
      ...<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
      ...<int>[11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
      ...<int>[21, 22, 23, 24, 25, 26, 27, 28, 29, 30],
      ...<int>[31, 32, 33, 34, 35, 36, 37, 38, 39, 40],
      ...<int>[41, 42, 43, 44, 45, 46, 47, 48, 49, 50],
      61,
      77,
      78,
      79,
      80,
      81,
      82,
      83,
      84,
      89,
    ];
    for (final id in supportedIds) {
      final rendered = normalizeSocialText('image_emoticon$id');
      expect(rendered, isNot(contains('image_emoticon')));
      expect(rendered, isNot('[表情]'));
    }
  });

  test('extracts paired and plain Xiaohongshu topics without duplicates', () {
    expect(extractXhsTopics('去露营 #新手露营[话题]# 也可以看 #户外生活 #户外生活'), <String>[
      '新手露营',
      '户外生活',
    ]);
  });

  testWidgets('Xiaohongshu topics use theme color and are tappable', (
    WidgetTester tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        home: Scaffold(
          body: SocialRichText(
            text: '正文 #新手露营[话题]# 结束',
            source: SourceId.xhs,
            onTopicTap: (String value) => selected = value,
          ),
        ),
      ),
    );

    final topic = tester.widget<Text>(find.text('#新手露营'));
    expect(
      topic.style?.color,
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme.primary,
    );
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Semantics && widget.properties.label == '话题 新手露营',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('#新手露营'));
    expect(selected, '新手露营');
  });

  test('comment decoding normalizes internal emoticon IDs', () {
    final comment = FeedComment.fromJson(<String, Object?>{
      'id': 'comment-1',
      'body': '这个表情 image_emoticon25',
      'author': <String, Object?>{'name': '用户'},
    }, SourceId.xhs);

    expect(comment.body, '这个表情 😏');
  });
}
