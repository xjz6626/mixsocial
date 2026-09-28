import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/library_backup.dart';
import 'package:mixsocial_mobile/src/library_manager_screen.dart';
import 'package:mixsocial_mobile/src/library_organizer.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _item = FeedItem(
  ref: ContentRef(source: SourceId.tieba, id: '123'),
  title: '本地帖子',
  author: Author(
    ref: ProfileRef(source: SourceId.tieba, id: 'u'),
    id: 'u',
    name: '作者',
  ),
  stats: ItemStats(),
);

class _Xhs implements XhsWebSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No platform writes allowed: ${invocation.memberName}');
}

class _Tieba implements TiebaSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No platform writes allowed: ${invocation.memberName}');
}

class _Controller extends MixsocialController {
  _Controller(LocalSettings settings)
    : super(xhs: _Xhs(), tieba: _Tieba(), settings: settings);
  final saved = <FeedItem>[_item];
  final later = <FeedItem>[];
  @override
  Future<List<FeedItem>> savedItems() async => saved.toList();
  @override
  Future<List<FeedItem>> readLaterItems() async => later.toList();
  @override
  Future<void> setLocalSaved(FeedItem item, bool value) async {
    saved.removeWhere((entry) => entry.key == item.key);
    if (value) saved.add(item);
  }

  @override
  Future<void> setReadLater(FeedItem item, bool value) async {
    later.removeWhere((entry) => entry.key == item.key);
    if (value) later.add(item);
  }
}

void main() {
  late _Controller controller;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    controller = _Controller(LocalSettings(SharedPreferencesAsync()));
  });
  tearDown(() => controller.dispose());

  testWidgets('create collection and batch add without platform writes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LibraryManagerScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建收藏夹'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '技术',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('技术 0'), findsOneWidget);
    await tester.longPress(find.byKey(const Key('organized-tieba:123')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入收藏夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('技术'));
    await tester.pumpAndSettle();
    expect(find.text('技术 1'), findsOneWidget);
    expect(controller.saved, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'backup validates first, requires confirmation and merges instead of replacing',
    (tester) async {
      final text = LibraryBackup.encode(
        saved: [_item],
        readLater: [_item],
        organization: LibraryOrganization(),
      );
      await tester.pumpWidget(
        MaterialApp(home: LibraryBackupScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('library-backup-input')),
        text,
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(20, 180), const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.tap(find.text('校验并预览'));
      await tester.pumpAndSettle();
      expect(controller.later, isEmpty);
      await tester.dragFrom(const Offset(20, 180), const Offset(0, -160));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认合并导入'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('确认合并备份？'), findsOneWidget);
      expect(controller.later, isEmpty);
      await tester.tap(find.text('合并导入'));
      await tester.pumpAndSettle();
      expect(controller.later.single.key, _item.key);
      expect(controller.saved, hasLength(1));
      expect(find.textContaining('没有发送平台互动请求'), findsOneWidget);
    },
  );

  testWidgets('backup rejects credential fields and does not mutate library', (
    tester,
  ) async {
    final raw =
        jsonDecode(
              LibraryBackup.encode(
                saved: [_item],
                readLater: [],
                organization: LibraryOrganization(),
              ),
            )
            as Map<String, dynamic>;
    raw['BDUSS'] = 'never-import-this';
    await tester.pumpWidget(
      MaterialApp(home: LibraryBackupScreen(controller: controller)),
    );
    await tester.enterText(
      find.byKey(const Key('library-backup-input')),
      jsonEncode(raw),
    );
    await tester.ensureVisible(find.text('校验并预览'));
    await tester.tap(find.text('校验并预览'));
    await tester.pumpAndSettle();
    expect(find.text('确认合并导入'), findsNothing);
    expect(find.textContaining('未知字段'), findsOneWidget);
    expect(controller.saved, hasLength(1));
    expect(controller.later, isEmpty);
  });
}
