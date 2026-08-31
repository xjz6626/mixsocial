import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/feed_widgets.dart';
import 'package:mixsocial_mobile/src/home_screen.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/network_media.dart';

const _item = FeedItem(
  ref: ContentRef(source: SourceId.xhs, id: 'note-1'),
  title: '一条用于组件测试的内容',
  summary: '摘要',
  author: Author(
    ref: ProfileRef(source: SourceId.xhs, id: 'author-1'),
    id: 'author-1',
    name: '测试作者',
  ),
  stats: ItemStats(likes: 12800, comments: 34),
);

const _itemWithMedia = FeedItem(
  ref: ContentRef(source: SourceId.tieba, id: 'thread-1'),
  title: '带图片的主题',
  author: Author(
    ref: ProfileRef(source: SourceId.tieba, id: 'tieba-author'),
    id: 'tieba-author',
    name: '贴吧作者',
  ),
  stats: ItemStats(),
  media: <MediaItem>[
    MediaItem(
      kind: 'image',
      url: 'https://example.com/preview.jpg',
      width: 1200,
      height: 900,
    ),
  ],
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

void main() {
  testWidgets('masonry card exposes source, title, author and like count', (
    WidgetTester tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(MasonryFeedCard(item: _item, onTap: () => tapped = true)),
    );

    expect(find.byKey(const Key('masonry-xhs-note-1')), findsOneWidget);
    expect(find.text('小红书'), findsOneWidget);
    expect(find.text('一条用于组件测试的内容'), findsOneWidget);
    expect(find.text('测试作者'), findsOneWidget);
    expect(find.text('1.3万'), findsOneWidget);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);

    await tester.tap(find.byKey(const Key('masonry-xhs-note-1')));
    expect(tapped, isTrue);
  });

  testWidgets('list card exposes both interaction counters', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(ListFeedCard(item: _item, onTap: () {})));

    expect(find.byKey(const Key('list-xhs-note-1')), findsOneWidget);
    expect(find.text('摘要'), findsOneWidget);
    expect(find.text('1.3万'), findsOneWidget);
    expect(find.text('34'), findsOneWidget);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
  });

  testWidgets('feed cards expose a separate author action', (
    WidgetTester tester,
  ) async {
    var openedAuthor = false;
    var openedNote = false;
    await tester.pumpWidget(
      _host(
        ListFeedCard(
          item: _item,
          onTap: () => openedNote = true,
          onAuthorTap: () => openedAuthor = true,
        ),
      ),
    );

    await tester.tap(find.text('测试作者'));
    expect(openedAuthor, isTrue);
    expect(openedNote, isFalse);
  });

  testWidgets('feed preview uses a bounded decode size and image semantics', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        _host(const FeedMediaPreview(item: _itemWithMedia, maxDimension: 480)),
      );

      final image = tester.widget<SourceNetworkImage>(
        find.byType(SourceNetworkImage),
      );
      expect(image.maxDimension, 480);
      expect(image.semanticLabel, '图片预览');
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('compactCount formats Chinese large-number units', () {
    expect(compactCount(9999), '9999');
    expect(compactCount(10000), '1.0万');
    expect(compactCount(123000), '12万');
    expect(compactCount(100000000), '1.0亿');
  });
}
