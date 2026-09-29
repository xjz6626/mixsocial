import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_controller.dart';
import 'device_transfer.dart';
import 'library_backup.dart';
import 'library_organizer.dart';
import 'models.dart';
import 'reading_state_store.dart';
import 'search_history.dart';

class DeviceTransferImportResult {
  const DeviceTransferImportResult({
    required this.localItems,
    required this.accounts,
    this.warnings = const <String>[],
  });

  final int localItems;
  final List<String> accounts;
  final List<String> warnings;
}

class DeviceTransferService {
  DeviceTransferService(this.controller, {SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const String _journalKey = 'deviceTransfer.importJournal.v1';

  final MixsocialController controller;
  final SharedPreferencesAsync _preferences;

  Future<DeviceTransferPayload> createPayload() async {
    final saved = await controller.savedItems();
    final readLater = await controller.readLaterItems();
    final history = await controller.historyItems();
    final organization = await controller.settings.organization.read();
    final reading = await ReadingStateStore().all();
    final search = SearchHistoryStore();
    final searchHistory = <SourceId, List<String>>{};
    for (final source in SourceId.values) {
      searchHistory[source] = await search.read(source);
    }
    final layouts = <SourceId, FeedLayout>{};
    for (final source in SourceId.values) {
      layouts[source] = await controller.settings.layoutFor(source);
    }
    final libraryJson = LibraryBackup.encode(
      saved: saved,
      readLater: readLater,
      organization: organization,
    );
    final historyJson = LibraryBackup.encode(
      saved: history.take(100).toList(),
      readLater: const <FeedItem>[],
      organization: LibraryOrganization(),
    );
    final tiebaCredential = await controller.tieba
        .exportCredentialForTransfer();
    final zhihuCredential = await controller.zhihu
        .exportCredentialForTransfer();
    final xhsCookies = await controller.xhs.exportCookiesForTransfer();
    return DeviceTransferPayload(
      createdAt: DateTime.now(),
      libraryJson: libraryJson,
      historyJson: historyJson,
      layouts: layouts,
      theme: await controller.settings.themePreference(),
      density: await controller.settings.feedDensity(),
      blockedForums: await controller.settings.blockedForums(),
      blockedKeywords: await controller.settings.blockedKeywords(),
      hideVideos: await controller.settings.hideVideos(),
      hideMedia: await controller.settings.hideMedia(),
      followingProfiles: await controller.settings.followingProfiles(),
      recentForums: await controller.settings.recentForums(),
      searchHistory: searchHistory,
      readingStates: reading,
      tiebaCredential: tiebaCredential,
      zhihuCredential: zhihuCredential,
      xhsCookies: xhsCookies,
    );
  }

  Future<DeviceTransferImportResult> importPayload(
    DeviceTransferPayload payload,
  ) async {
    // Re-encode and decode before any write. This also catches payloads created
    // programmatically rather than by the QR receiver.
    final checked = DeviceTransferPayload.decode(payload.encode());
    final payloadId = await _payloadId(checked);
    final completed = await _readJournal(payloadId);
    await _checkLibraryLimits(checked.library);

    await _runPhase(payloadId, completed, 'library', () async {
      await _mergeLibrary(checked.library);
    });
    await _runPhase(payloadId, completed, 'history', () async {
      for (final entry in checked.history.entries.reversed) {
        await controller.settings.addHistory(entry.item);
      }
    });
    await _runPhase(payloadId, completed, 'reader', () async {
      final readingStore = ReadingStateStore();
      final existingReading = await readingStore.all();
      for (final entry in checked.readingStates.entries) {
        final previous = existingReading[entry.key];
        if (previous == null ||
            previous.updatedAt.isBefore(entry.value.updatedAt)) {
          await readingStore.save(entry.key, entry.value);
        }
      }
      final searchStore = SearchHistoryStore();
      for (final entry in checked.searchHistory.entries) {
        await searchStore.merge(entry.key, entry.value);
      }
      for (final forum in checked.recentForums.reversed) {
        await controller.settings.addRecentForum(forum);
      }
    });
    await _runPhase(payloadId, completed, 'preferences', () async {
      for (final entry in checked.layouts.entries) {
        await controller.settings.setLayout(entry.key, entry.value);
      }
      await controller.settings.setThemePreference(checked.theme);
      await controller.settings.setFeedDensity(checked.density);
      await controller.settings.setHideVideos(checked.hideVideos);
      await controller.settings.setHideMedia(checked.hideMedia);
      for (final forum in checked.blockedForums) {
        await controller.settings.setForumBlocked(forum, true);
      }
      for (final keyword in checked.blockedKeywords) {
        await controller.settings.setKeywordBlocked(keyword, true);
      }
      await controller.settings.mergeFollowingProfiles(
        checked.followingProfiles,
      );
    });

    final restoredAccounts = <String>[];
    final warnings = <String>[];
    Future<void> restore(String label, Future<void> Function() action) async {
      try {
        await action();
        restoredAccounts.add(label);
      } catch (_) {
        warnings.add('$label账号未能恢复，可稍后在“我的”中重新登录');
      }
    }

    if (checked.xhsCookies.isNotEmpty) {
      await restore(
        '小红书',
        () => controller.xhs.importCookiesFromTransfer(checked.xhsCookies),
      );
    }
    if (checked.tiebaCredential case final credential?) {
      await restore(
        '贴吧',
        () => controller.tieba.importCredentialFromTransfer(credential),
      );
    }
    if (checked.zhihuCredential case final credential?) {
      await restore(
        '知乎',
        () => controller.zhihu.importCredentialFromTransfer(credential),
      );
    }
    await controller.reloadLocalPreferences();
    await _preferences.remove(_journalKey);
    return DeviceTransferImportResult(
      localItems: checked.localItemCount,
      accounts: restoredAccounts,
      warnings: warnings,
    );
  }

  Future<String> _payloadId(DeviceTransferPayload payload) async {
    final digest = await Sha256().hash(utf8.encode(payload.encode()));
    return base64Url.encode(digest.bytes.take(18).toList());
  }

  Future<Set<String>> _readJournal(String payloadId) async {
    try {
      final raw = await _preferences.getString(_journalKey);
      if (raw == null) {
        await _writeJournal(payloadId, const <String>{});
        return <String>{};
      }
      final value = (jsonDecode(raw) as Map).cast<String, Object?>();
      if (value['payloadId'] != payloadId) {
        await _writeJournal(payloadId, const <String>{});
        return <String>{};
      }
      final phases = value['completed'];
      if (phases is! List || phases.any((item) => item is! String)) {
        throw const FormatException('迁移恢复日志无效');
      }
      return phases.cast<String>().toSet();
    } catch (_) {
      await _writeJournal(payloadId, const <String>{});
      return <String>{};
    }
  }

  Future<void> _runPhase(
    String payloadId,
    Set<String> completed,
    String phase,
    Future<void> Function() action,
  ) async {
    if (completed.contains(phase)) return;
    await action();
    completed.add(phase);
    await _writeJournal(payloadId, completed);
  }

  Future<void> _writeJournal(String payloadId, Set<String> completed) =>
      _preferences.setString(
        _journalKey,
        jsonEncode(<String, Object?>{
          'version': 1,
          'payloadId': payloadId,
          'completed': completed.toList()..sort(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );

  Future<void> _checkLibraryLimits(LibraryBackup backup) async {
    final saved = await controller.savedItems();
    final later = await controller.readLaterItems();
    final organization = await controller.settings.organization.read();
    if ({
          ...saved.map((item) => item.key),
          ...backup.entries
              .where((entry) => entry.saved)
              .map((entry) => entry.item.key),
        }.length >
        300) {
      throw const FormatException('合并后本地收藏超过 300 条，请先整理');
    }
    if ({
          ...later.map((item) => item.key),
          ...backup.entries
              .where((entry) => entry.readLater)
              .map((entry) => entry.item.key),
        }.length >
        300) {
      throw const FormatException('合并后稍后阅读超过 300 条，请先整理');
    }
    if ({
          ...organization.collections.keys.map((name) => name.toLowerCase()),
          ...backup.collections.map((name) => name.toLowerCase()),
        }.length >
        100) {
      throw const FormatException('合并后收藏夹超过 100 个，请先整理');
    }
  }

  Future<void> _mergeLibrary(LibraryBackup backup) async {
    final saved = await controller.savedItems();
    final later = await controller.readLaterItems();
    final store = controller.settings.organization;
    final organization = await store.read();
    final savedKeys = saved.map((item) => item.key).toSet();
    final laterKeys = later.map((item) => item.key).toSet();
    final existing = <String, FeedItem>{
      ...organization.items,
      for (final item in later) item.key: item,
      for (final item in saved) item.key: item,
    };
    for (final name in backup.collections) {
      await store.create(name);
    }
    for (final entry in backup.entries) {
      final item = existing[entry.item.key] ?? entry.item;
      if (entry.saved && savedKeys.add(item.key)) {
        await controller.setLocalSaved(item, true);
      }
      if (entry.readLater && laterKeys.add(item.key)) {
        await controller.setReadLater(item, true);
      }
      for (final name in entry.collections) {
        await store.setMembership(name, <FeedItem>[item], true);
      }
      final tags = LibraryOrganizerStore.normalizeTags(<String>[
        ...?organization.tags[item.key],
        ...entry.tags,
      ]);
      if (tags.isNotEmpty) await store.setTags(item, tags);
    }
  }
}
