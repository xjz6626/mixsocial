import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/design_system.dart';
import 'package:mixsocial_mobile/src/device_transfer.dart';
import 'package:mixsocial_mobile/src/device_transfer_pending.dart';
import 'package:mixsocial_mobile/src/library_backup.dart';
import 'package:mixsocial_mobile/src/library_organizer.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/reading_state_store.dart';

void main() {
  group('device transfer payload', () {
    test('round trips allowlisted local data and credentials', () {
      final payload = _payload();
      final decoded = DeviceTransferPayload.decode(payload.encode());

      expect(decoded.library.savedCount, 1);
      expect(decoded.history.entries, hasLength(1));
      expect(decoded.layouts[SourceId.zhihu], FeedLayout.list);
      expect(decoded.theme, AppThemePreference.dark);
      expect(decoded.readingStates['tieba:123']?.page, 3);
      expect(decoded.accountLabels, <String>['小红书', '贴吧', '知乎']);
    });

    test('rejects unknown fields before import', () {
      final json = jsonDecode(_payload().encode()) as Map<String, dynamic>;
      json['credentials']['plaintextBackup'] = 'unexpected';

      expect(
        () => DeviceTransferPayload.decode(jsonEncode(json)),
        throwsFormatException,
      );
    });
  });

  group('device transfer ticket', () {
    test('round trips private LAN connection data', () {
      final ticket = DeviceTransferTicket(
        address: InternetAddress('192.168.50.8'),
        port: 34876,
        token: 'abcdefghijklmnopqrstuvwx',
        key: Uint8List.fromList(List<int>.generate(32, (index) => index)),
      );

      final decoded = DeviceTransferTicket.decode(ticket.encode());
      expect(decoded.address.address, '192.168.50.8');
      expect(decoded.port, 34876);
      expect(decoded.key, ticket.key);
      expect(decoded.verificationCode, hasLength(6));
    });

    test('rejects public addresses', () {
      final value = Uri(
        scheme: 'mixsocial',
        host: 'transfer',
        queryParameters: <String, String>{
          'v': '1',
          'host': '8.8.8.8',
          'port': '34876',
          'token': 'abcdefghijklmnopqrstuvwx',
          'key': base64Url.encode(List<int>.filled(32, 1)),
        },
      ).toString();

      expect(() => DeviceTransferTicket.decode(value), throwsFormatException);
    });
  });

  group('pending device transfer', () {
    test('survives restart without writing plaintext credentials', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final temporary = await Directory.systemTemp.createTemp(
        'mixsocial-transfer-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      Future<Directory> directory() async => temporary;
      final store = DeviceTransferPendingStore(directory: directory);

      await store.stage(_payload(), '123456');

      final files = await temporary
          .list(recursive: true)
          .where((entity) => entity is File)
          .cast<File>()
          .toList();
      expect(files, hasLength(1));
      final encrypted = await files.single.readAsBytes();
      expect(
        utf8.decode(encrypted, allowMalformed: true),
        isNot(contains('BDUSS')),
      );

      final restartedStore = DeviceTransferPendingStore(directory: directory);
      final restored = await restartedStore.load();
      expect(restored?.verificationCode, '123456');
      expect(restored?.payload.tiebaCredential, 'BDUSS=secret');

      await restartedStore.clear();
      expect(await restartedStore.load(), isNull);
      expect(
        await temporary
            .list(recursive: true)
            .where((entity) => entity is File)
            .cast<File>()
            .toList(),
        isEmpty,
      );
    });
  });

  test('one-time socket transfer decrypts on the receiving device', () async {
    final sender = await DeviceTransferSender.start(
      _payload(),
      advertisedAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(sender.close);

    final received = await DeviceTransferSender.receive(sender.ticket);

    expect(received.library.savedCount, 1);
    expect(sender.state.value, DeviceTransferSenderState.sent);
  });

  test('wrong QR key cannot decrypt the transfer', () async {
    final sender = await DeviceTransferSender.start(
      _payload(),
      advertisedAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(sender.close);
    final wrongTicket = DeviceTransferTicket(
      address: sender.ticket.address,
      port: sender.ticket.port,
      token: sender.ticket.token,
      key: Uint8List.fromList(List<int>.filled(32, 9)),
    );

    await expectLater(
      DeviceTransferSender.receive(wrongTicket),
      throwsFormatException,
    );
  });
}

DeviceTransferPayload _payload() {
  final item = FeedItem(
    ref: const ContentRef(
      source: SourceId.tieba,
      id: '123',
      url: 'https://tieba.baidu.com/p/123',
    ),
    title: '测试帖子',
    summary: '只会迁移公开文字',
    author: const Author(
      ref: ProfileRef(source: SourceId.tieba, id: '7'),
      id: '7',
      name: '作者',
    ),
    stats: const ItemStats(),
    tags: const <String>['测试'],
  );
  final library = LibraryBackup.encode(
    saved: <FeedItem>[item],
    readLater: <FeedItem>[item],
    organization: LibraryOrganization(
      collections: <String, List<String>>{
        '稍后整理': <String>[item.key],
      },
      items: <String, FeedItem>{item.key: item},
    ),
  );
  final history = LibraryBackup.encode(
    saved: <FeedItem>[item],
    readLater: const <FeedItem>[],
    organization: LibraryOrganization(),
  );
  return DeviceTransferPayload(
    createdAt: DateTime.utc(2026, 9, 29),
    libraryJson: library,
    historyJson: history,
    layouts: const <SourceId, FeedLayout>{
      SourceId.all: FeedLayout.masonry,
      SourceId.xhs: FeedLayout.masonry,
      SourceId.tieba: FeedLayout.list,
      SourceId.zhihu: FeedLayout.list,
    },
    theme: AppThemePreference.dark,
    density: FeedDensity.compact,
    blockedForums: const <String>{'广告吧'},
    blockedKeywords: const <String>{'广告'},
    hideVideos: true,
    hideMedia: false,
    followingProfiles: const <String>{'tieba:7'},
    recentForums: const <String>['测试'],
    searchHistory: const <SourceId, List<String>>{
      SourceId.all: <String>['Flutter'],
    },
    readingStates: <String, ReadingState>{
      item.key: ReadingState(page: 3, updatedAt: DateTime.utc(2026, 9, 29)),
    },
    tiebaCredential: 'BDUSS=secret',
    zhihuCredential: '_xsrf=a; d_c0=b; z_c0=c',
    xhsCookies: const <Map<String, String>>[
      <String, String>{'name': 'web_session', 'value': 'secret'},
    ],
  );
}
