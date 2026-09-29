import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'device_transfer.dart';

class PendingDeviceTransfer {
  const PendingDeviceTransfer({
    required this.payload,
    required this.verificationCode,
  });

  final DeviceTransferPayload payload;
  final String verificationCode;
}

/// Crash-safe encrypted staging for an import that has not completed yet.
///
/// A new immutable blob is written and flushed before the secure metadata
/// pointer changes. A crash therefore leaves either the old complete slot or
/// the new complete slot readable, never a half-written credential document.
class DeviceTransferPendingStore {
  DeviceTransferPendingStore({
    this.secureStorage = const FlutterSecureStorage(),
    Future<Directory> Function()? directory,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  static const String _metadataKey = 'deviceTransfer.pending.v1';
  static const int _version = 1;
  static const int _maximumBytes = 8 * 1024 * 1024 + 29;

  final FlutterSecureStorage secureStorage;
  final Future<Directory> Function() _directory;

  Future<void> stage(
    DeviceTransferPayload payload,
    String verificationCode,
  ) async {
    if (!RegExp(r'^\d{6}$').hasMatch(verificationCode)) {
      throw const FormatException('迁移校验码无效');
    }
    final id = _randomId();
    final key = _randomBytes(32);
    final nonce = _randomBytes(12);
    final clear = utf8.encode(
      jsonEncode(<String, Object?>{
        'verificationCode': verificationCode,
        'payload': jsonDecode(payload.encode()),
      }),
    );
    final box = await AesGcm.with256bits().encrypt(
      clear,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode('mixsocial-pending-transfer-v1'),
    );
    final bytes = Uint8List.fromList(<int>[
      _version,
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
    if (bytes.length > _maximumBytes) {
      throw const FormatException('待迁移数据过大');
    }

    final directory = await _transferDirectory();
    final file = File(path.join(directory.path, 'pending-$id.bin'));
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    await secureStorage.write(
      key: _metadataKey,
      value: jsonEncode(<String, String>{
        'id': id,
        'key': base64Url.encode(key),
      }),
    );
    await _prune(directory, keepId: id);
  }

  Future<PendingDeviceTransfer?> load() async {
    final raw = await secureStorage.read(key: _metadataKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final metadata = (jsonDecode(raw) as Map).cast<String, Object?>();
      final id = metadata['id'];
      final encodedKey = metadata['key'];
      if (id is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
          encodedKey is! String) {
        throw const FormatException('待迁移记录无效');
      }
      final key = base64Url.decode(encodedKey);
      if (key.length != 32) throw const FormatException('待迁移密钥无效');
      final directory = await _transferDirectory();
      final file = File(path.join(directory.path, 'pending-$id.bin'));
      final bytes = await file.readAsBytes();
      if (bytes.length < 30 ||
          bytes.length > _maximumBytes ||
          bytes.first != _version) {
        throw const FormatException('待迁移密文无效');
      }
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          bytes.sublist(29),
          nonce: bytes.sublist(1, 13),
          mac: Mac(bytes.sublist(13, 29)),
        ),
        secretKey: SecretKey(key),
        aad: utf8.encode('mixsocial-pending-transfer-v1'),
      );
      final document = (jsonDecode(utf8.decode(clear)) as Map)
          .cast<String, Object?>();
      final verificationCode = document['verificationCode'];
      if (verificationCode is! String ||
          !RegExp(r'^\d{6}$').hasMatch(verificationCode)) {
        throw const FormatException('待迁移校验码无效');
      }
      final payload = DeviceTransferPayload.decode(
        jsonEncode(document['payload']),
      );
      await _prune(directory, keepId: id);
      return PendingDeviceTransfer(
        payload: payload,
        verificationCode: verificationCode,
      );
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<void> clear() async {
    await secureStorage.delete(key: _metadataKey);
    final directory = await _transferDirectory();
    await _prune(directory);
  }

  Future<Directory> _transferDirectory() async {
    final parent = await _directory();
    return Directory(path.join(parent.path, 'device_transfer'))
      ..createSync(recursive: true);
  }

  Future<void> _prune(Directory directory, {String? keepId}) async {
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = path.basename(entity.path);
      if (keepId != null && name == 'pending-$keepId.bin') continue;
      if (RegExp(r'^pending-[a-f0-9]{32}\.bin(?:\.tmp)?$').hasMatch(name)) {
        try {
          await entity.delete();
        } on FileSystemException {
          // A later load/stage pass retries orphan cleanup.
        }
      }
    }
  }
}

String _randomId() => _randomBytes(
  16,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}
