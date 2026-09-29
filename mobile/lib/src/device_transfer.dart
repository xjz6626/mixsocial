import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'design_system.dart';
import 'library_backup.dart';
import 'models.dart';
import 'reading_state_store.dart';

const String _transferFormat = 'mixsocial-device-transfer';
const int _transferVersion = 1;
const int _maxPlainBytes = 8 * 1024 * 1024;
const int _maxWireBytes = _maxPlainBytes + 29;

class DeviceTransferPayload {
  DeviceTransferPayload({
    required this.createdAt,
    required this.libraryJson,
    required this.historyJson,
    required this.layouts,
    required this.theme,
    required this.density,
    required this.blockedForums,
    required this.blockedKeywords,
    required this.hideVideos,
    required this.hideMedia,
    required this.followingProfiles,
    required this.recentForums,
    required this.searchHistory,
    required this.readingStates,
    this.tiebaCredential,
    this.zhihuCredential,
    this.xhsCookies = const <Map<String, String>>[],
  }) : library = LibraryBackup.decode(libraryJson),
       history = LibraryBackup.decode(historyJson);

  final DateTime createdAt;
  final String libraryJson;
  final String historyJson;
  final LibraryBackup library;
  final LibraryBackup history;
  final Map<SourceId, FeedLayout> layouts;
  final AppThemePreference theme;
  final FeedDensity density;
  final Set<String> blockedForums;
  final Set<String> blockedKeywords;
  final bool hideVideos;
  final bool hideMedia;
  final Set<String> followingProfiles;
  final List<String> recentForums;
  final Map<SourceId, List<String>> searchHistory;
  final Map<String, ReadingState> readingStates;
  final String? tiebaCredential;
  final String? zhihuCredential;
  final List<Map<String, String>> xhsCookies;

  List<String> get accountLabels => <String>[
    if (xhsCookies.any((cookie) => cookie['name'] == 'web_session')) '小红书',
    if (tiebaCredential != null) '贴吧',
    if (zhihuCredential != null) '知乎',
  ];

  int get localItemCount => library.entries.length + history.entries.length;

  String encode() {
    final value = jsonEncode(<String, Object?>{
      'format': _transferFormat,
      'version': _transferVersion,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'library': jsonDecode(libraryJson),
      'history': jsonDecode(historyJson),
      'preferences': <String, Object?>{
        'layouts': <String, String>{
          for (final entry in layouts.entries) entry.key.id: entry.value.name,
        },
        'theme': theme.name,
        'density': density.name,
        'blockedForums': blockedForums.toList()..sort(),
        'blockedKeywords': blockedKeywords.toList()..sort(),
        'hideVideos': hideVideos,
        'hideMedia': hideMedia,
        'followingProfiles': followingProfiles.toList()..sort(),
        'recentForums': recentForums,
        'searchHistory': <String, List<String>>{
          for (final entry in searchHistory.entries) entry.key.id: entry.value,
        },
        'readingStates': <String, Object?>{
          for (final entry in readingStates.entries)
            entry.key: entry.value.toJson(),
        },
      },
      'credentials': <String, Object?>{
        if (tiebaCredential != null) 'tieba': tiebaCredential,
        if (zhihuCredential != null) 'zhihu': zhihuCredential,
        if (xhsCookies.isNotEmpty) 'xhs': xhsCookies,
      },
    });
    if (utf8.encode(value).length > _maxPlainBytes) {
      throw const FormatException('迁移数据超过 8 MiB，请先精简本地收藏');
    }
    return value;
  }

  factory DeviceTransferPayload.decode(String text) {
    if (text.length > _maxPlainBytes ||
        utf8.encode(text).length > _maxPlainBytes) {
      throw const FormatException('迁移数据超过 8 MiB');
    }
    final root = _object(jsonDecode(text), '迁移数据结构无效');
    _exactKeys(root, const <String>{
      'format',
      'version',
      'createdAt',
      'library',
      'history',
      'preferences',
      'credentials',
    });
    if (root['format'] != _transferFormat ||
        root['version'] != _transferVersion) {
      throw const FormatException('不支持的迁移数据版本');
    }
    final createdAt = DateTime.tryParse(root['createdAt']?.toString() ?? '');
    if (createdAt == null) throw const FormatException('迁移时间无效');
    final libraryJson = jsonEncode(_object(root['library'], '收藏数据无效'));
    final historyJson = jsonEncode(_object(root['history'], '历史数据无效'));
    final library = LibraryBackup.decode(libraryJson);
    final history = LibraryBackup.decode(historyJson);
    if (history.entries.length > 100) {
      throw const FormatException('浏览历史超过 100 条');
    }

    final preferences = _object(root['preferences'], '偏好设置无效');
    _exactKeys(preferences, const <String>{
      'layouts',
      'theme',
      'density',
      'blockedForums',
      'blockedKeywords',
      'hideVideos',
      'hideMedia',
      'followingProfiles',
      'recentForums',
      'searchHistory',
      'readingStates',
    });
    final rawLayouts = _object(preferences['layouts'], '布局设置无效');
    final layouts = <SourceId, FeedLayout>{};
    for (final entry in rawLayouts.entries) {
      final source = SourceId.values
          .where((item) => item.id == entry.key)
          .firstOrNull;
      final layout = FeedLayout.values
          .where((item) => item.name == entry.value)
          .firstOrNull;
      if (source == null || layout == null) {
        throw const FormatException('布局设置无效');
      }
      layouts[source] = layout;
    }
    final theme = AppThemePreference.values
        .where((item) => item.name == preferences['theme'])
        .firstOrNull;
    final density = FeedDensity.values
        .where((item) => item.name == preferences['density'])
        .firstOrNull;
    if (theme == null ||
        density == null ||
        preferences['hideVideos'] is! bool ||
        preferences['hideMedia'] is! bool) {
      throw const FormatException('外观或内容设置无效');
    }
    final blockedForums = _strings(preferences['blockedForums'], 500, 80);
    final blockedKeywords = _strings(preferences['blockedKeywords'], 500, 100);
    final followingProfiles = _strings(
      preferences['followingProfiles'],
      2000,
      240,
    );
    final recentForums = _strings(preferences['recentForums'], 20, 80).toList();

    final rawSearch = _object(preferences['searchHistory'], '搜索历史无效');
    final searchHistory = <SourceId, List<String>>{};
    for (final entry in rawSearch.entries) {
      final source = SourceId.values
          .where((item) => item.id == entry.key)
          .firstOrNull;
      if (source == null) throw const FormatException('搜索历史平台无效');
      searchHistory[source] = _strings(entry.value, 20, 200).toList();
    }
    final rawReading = _object(preferences['readingStates'], '阅读进度无效');
    if (rawReading.length > 1200) throw const FormatException('阅读进度过多');
    final readingStates = <String, ReadingState>{};
    for (final entry in rawReading.entries) {
      if (entry.key.isEmpty || entry.key.length > 200) {
        throw const FormatException('阅读进度条目标识无效');
      }
      readingStates[entry.key] = ReadingState.fromJson(
        _object(entry.value, '阅读进度无效').cast<String, dynamic>(),
      );
    }

    final credentials = _object(root['credentials'], '账号数据无效');
    _allowedKeys(credentials, const <String>{'tieba', 'zhihu', 'xhs'});
    final tieba = _optionalCredential(credentials['tieba'], 8192, '贴吧');
    final zhihu = _optionalCredential(credentials['zhihu'], 65536, '知乎');
    final rawCookies = credentials['xhs'] ?? const <Object?>[];
    if (rawCookies is! List || rawCookies.length > 200) {
      throw const FormatException('小红书 Cookie 数量无效');
    }
    final xhsCookies = <Map<String, String>>[];
    final names = <String>{};
    for (final value in rawCookies) {
      final cookie = _object(value, '小红书 Cookie 无效');
      _exactKeys(cookie, const <String>{'name', 'value'});
      final name = cookie['name'];
      final cookieValue = cookie['value'];
      if (name is! String ||
          !RegExp(r'^[!#$%&\x27*+.^_`|~0-9A-Za-z-]{1,256}$').hasMatch(name) ||
          cookieValue is! String ||
          cookieValue.isEmpty ||
          cookieValue.length > 16384 ||
          cookieValue.contains(RegExp(r'[\r\n]')) ||
          !names.add(name)) {
        throw const FormatException('小红书 Cookie 无效');
      }
      xhsCookies.add(<String, String>{'name': name, 'value': cookieValue});
    }

    return DeviceTransferPayload(
      createdAt: createdAt,
      libraryJson: libraryJson,
      historyJson: historyJson,
      layouts: layouts,
      theme: theme,
      density: density,
      blockedForums: blockedForums,
      blockedKeywords: blockedKeywords,
      hideVideos: preferences['hideVideos']! as bool,
      hideMedia: preferences['hideMedia']! as bool,
      followingProfiles: followingProfiles,
      recentForums: recentForums,
      searchHistory: searchHistory,
      readingStates: readingStates,
      tiebaCredential: tieba,
      zhihuCredential: zhihu,
      xhsCookies: xhsCookies,
    ).._verifyDecoded(library, history);
  }

  void _verifyDecoded(
    LibraryBackup decodedLibrary,
    LibraryBackup decodedHistory,
  ) {
    if (decodedLibrary.entries.length != library.entries.length ||
        decodedHistory.entries.length != history.entries.length) {
      throw const FormatException('迁移数据校验失败');
    }
  }
}

class DeviceTransferTicket {
  const DeviceTransferTicket({
    required this.address,
    required this.port,
    required this.token,
    required this.key,
  });

  final InternetAddress address;
  final int port;
  final String token;
  final Uint8List key;

  String get verificationCode {
    final value = (key[0] << 16) | (key[1] << 8) | key[2];
    return (value % 1000000).toString().padLeft(6, '0');
  }

  String encode() => Uri(
    scheme: 'mixsocial',
    host: 'transfer',
    queryParameters: <String, String>{
      'v': '1',
      'host': address.address,
      'port': '$port',
      'token': token,
      'key': base64Url.encode(key),
    },
  ).toString();

  factory DeviceTransferTicket.decode(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'mixsocial' ||
        uri.host != 'transfer' ||
        uri.queryParameters['v'] != '1') {
      throw const FormatException('这不是 Mixsocial 设备迁移二维码');
    }
    final address = InternetAddress.tryParse(uri.queryParameters['host'] ?? '');
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final token = uri.queryParameters['token'] ?? '';
    Uint8List key;
    try {
      key = base64Url.decode(uri.queryParameters['key'] ?? '');
    } catch (_) {
      throw const FormatException('迁移二维码密钥无效');
    }
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        !_isPrivateAddress(address) ||
        port == null ||
        port < 1024 ||
        port > 65535 ||
        !RegExp(r'^[A-Za-z0-9_-]{16,64}={0,2}$').hasMatch(token) ||
        key.length != 32) {
      throw const FormatException('迁移二维码连接信息无效');
    }
    return DeviceTransferTicket(
      address: address,
      port: port,
      token: token,
      key: key,
    );
  }
}

enum DeviceTransferSenderState { waiting, sent, expired, cancelled, failed }

class DeviceTransferSender {
  DeviceTransferSender._(
    this._server,
    this._wire,
    this.ticket,
    this.expiresAt,
  ) {
    _subscription = _server.listen(_handleClient, onError: _handleError);
    _timer = Timer(expiresAt.difference(DateTime.now()), () {
      _finish(DeviceTransferSenderState.expired);
    });
  }

  final ServerSocket _server;
  final Uint8List _wire;
  final DeviceTransferTicket ticket;
  final DateTime expiresAt;
  final ValueNotifier<DeviceTransferSenderState> state =
      ValueNotifier<DeviceTransferSenderState>(
        DeviceTransferSenderState.waiting,
      );
  late final StreamSubscription<Socket> _subscription;
  late final Timer _timer;
  bool _claimed = false;

  static Future<DeviceTransferSender> start(
    DeviceTransferPayload payload, {
    InternetAddress? advertisedAddress,
    Duration lifetime = const Duration(minutes: 2),
  }) async {
    final encrypted = await _encryptPayload(payload.encode());
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      final address = advertisedAddress ?? await _selectLanAddress();
      final token = base64Url.encode(_randomBytes(18));
      final ticket = DeviceTransferTicket(
        address: address,
        port: server.port,
        token: token,
        key: encrypted.key,
      );
      return DeviceTransferSender._(
        server,
        encrypted.wire,
        ticket,
        DateTime.now().add(lifetime),
      );
    } catch (_) {
      await server.close();
      rethrow;
    }
  }

  void _handleClient(Socket socket) {
    if (_claimed || state.value != DeviceTransferSenderState.waiting) {
      socket.destroy();
      return;
    }
    unawaited(_serve(socket));
  }

  Future<void> _serve(Socket socket) async {
    try {
      final supplied = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 8));
      if (supplied != ticket.token || _claimed) {
        socket.destroy();
        return;
      }
      _claimed = true;
      await _server.close();
      final header = ByteData(4)..setUint32(0, _wire.length, Endian.big);
      socket.add(header.buffer.asUint8List());
      socket.add(_wire);
      await socket.flush();
      await socket.close();
      _finish(DeviceTransferSenderState.sent);
    } catch (_) {
      socket.destroy();
      if (_claimed) _finish(DeviceTransferSenderState.failed);
    }
  }

  void _handleError(Object _) {
    if (!_claimed) _finish(DeviceTransferSenderState.failed);
  }

  Future<void> close() async {
    if (state.value == DeviceTransferSenderState.waiting) {
      state.value = DeviceTransferSenderState.cancelled;
    }
    _timer.cancel();
    await _subscription.cancel();
    await _server.close();
  }

  void _finish(DeviceTransferSenderState value) {
    if (state.value != DeviceTransferSenderState.waiting) return;
    state.value = value;
    _timer.cancel();
    unawaited(_subscription.cancel());
    unawaited(_server.close());
  }

  static Future<DeviceTransferPayload> receive(
    DeviceTransferTicket ticket, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final socket = await Socket.connect(
      ticket.address,
      ticket.port,
      timeout: timeout,
    );
    try {
      socket.write('${ticket.token}\n');
      await socket.flush();
      final bytes = <int>[];
      int? expected;
      await for (final chunk in socket.timeout(timeout)) {
        bytes.addAll(chunk);
        if (expected == null && bytes.length >= 4) {
          expected = ByteData.sublistView(
            Uint8List.fromList(bytes.take(4).toList()),
          ).getUint32(0, Endian.big);
          if (expected < 30 || expected > _maxWireBytes) {
            throw const FormatException('迁移数据长度无效');
          }
        }
        if (expected != null && bytes.length >= expected + 4) break;
        if (bytes.length > _maxWireBytes + 4) {
          throw const FormatException('迁移数据过大');
        }
      }
      if (expected == null || bytes.length != expected + 4) {
        throw const FormatException('迁移连接提前断开');
      }
      final plain = await _decryptPayload(
        Uint8List.fromList(bytes.sublist(4)),
        ticket.key,
      );
      return DeviceTransferPayload.decode(plain);
    } finally {
      socket.destroy();
    }
  }
}

class _EncryptedTransfer {
  const _EncryptedTransfer(this.key, this.wire);
  final Uint8List key;
  final Uint8List wire;
}

Future<_EncryptedTransfer> _encryptPayload(String value) async {
  final plain = utf8.encode(value);
  final key = _randomBytes(32);
  final nonce = _randomBytes(12);
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: utf8.encode('mixsocial-device-transfer-v1'),
  );
  final wire = Uint8List.fromList(<int>[
    _transferVersion,
    ...box.nonce,
    ...box.mac.bytes,
    ...box.cipherText,
  ]);
  if (wire.length > _maxWireBytes) {
    throw const FormatException('加密后的迁移数据超过 8 MiB');
  }
  return _EncryptedTransfer(key, wire);
}

Future<String> _decryptPayload(Uint8List wire, Uint8List key) async {
  if (wire.length < 30 || wire.first != _transferVersion || key.length != 32) {
    throw const FormatException('迁移密文格式无效');
  }
  try {
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(
        wire.sublist(29),
        nonce: wire.sublist(1, 13),
        mac: Mac(wire.sublist(13, 29)),
      ),
      secretKey: SecretKey(key),
      aad: utf8.encode('mixsocial-device-transfer-v1'),
    );
    if (clear.length > _maxPlainBytes) {
      throw const FormatException('解密后的迁移数据过大');
    }
    return utf8.decode(clear);
  } catch (error) {
    if (error is FormatException) rethrow;
    throw const FormatException('迁移数据无法解密或已被修改');
  }
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Future<InternetAddress> _selectLanAddress() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: true,
  );
  final candidates = <({String name, InternetAddress address})>[
    for (final interface in interfaces)
      for (final address in interface.addresses)
        if (_isPrivateAddress(address))
          (name: interface.name.toLowerCase(), address: address),
  ];
  int priority(String name) {
    if (name.startsWith('wlan') || name.contains('wifi')) return 0;
    if (name.startsWith('ap') || name.startsWith('en')) return 1;
    return 2;
  }

  candidates.sort(
    (left, right) => priority(left.name).compareTo(priority(right.name)),
  );
  if (candidates.isEmpty) {
    throw StateError('没有找到可用的局域网 IPv4 地址，请连接同一 Wi-Fi 后重试');
  }
  return candidates.first.address;
}

bool _isPrivateAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final bytes = address.rawAddress;
  return bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 169 && bytes[1] == 254);
}

Map<String, Object?> _object(Object? value, String message) {
  if (value is! Map) throw FormatException(message);
  try {
    return value.cast<String, Object?>();
  } catch (_) {
    throw FormatException(message);
  }
}

void _exactKeys(Map<String, Object?> value, Set<String> expected) {
  if (value.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(value.keys.toSet()).isNotEmpty) {
    throw const FormatException('迁移数据字段不完整或包含未知字段');
  }
}

void _allowedKeys(Map<String, Object?> value, Set<String> allowed) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('账号数据包含未知字段');
  }
}

Set<String> _strings(Object? value, int maxCount, int maxLength) {
  if (value is! List || value.length > maxCount) {
    throw const FormatException('迁移列表无效或过长');
  }
  final result = <String>{};
  for (final item in value) {
    if (item is! String || item.trim().isEmpty || item.length > maxLength) {
      throw const FormatException('迁移文本字段无效或过长');
    }
    result.add(item.trim());
  }
  return result;
}

String? _optionalCredential(Object? value, int maxLength, String label) {
  if (value == null) return null;
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maxLength ||
      value.contains(RegExp(r'[\r\n]'))) {
    throw FormatException('$label登录凭据无效');
  }
  return value.trim();
}
