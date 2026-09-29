import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_database.dart';
import 'models.dart';

/// Keeps an offline copy of a library list and journals edits made while
/// SQLite is unavailable. Replaying edits does not replace newer SQLite rows.
class LibraryRecovery {
  LibraryRecovery(this._preferences, this.kind);

  final SharedPreferencesAsync _preferences;
  final String kind;

  static final Map<String, Future<void>> _tails = <String, Future<void>>{};

  String get _key => 'library.$kind.recovery.v1';
  String get _legacyKey => 'library.$kind';
  int get _limit =>
      kind == 'history' ? LocalDatabase.historyLimit : LocalDatabase.savedLimit;

  Future<List<FeedItem>> read() => _serial(() async => (await _load()).items);

  Future<void> addHistory(FeedItem item) => _serial(() async {
    final state = await _load();
    final items = <FeedItem>[
      item,
      ...state.items.where((value) => value.key != item.key),
    ].take(_limit).toList();
    final edits = <_LibraryEdit>[
      ...state.edits.where((edit) => edit.item?.key != item.key),
      _LibraryEdit('history', item),
    ];
    await _write(_LibraryState(items, edits));
  });

  Future<void> clearHistory() => _serial(() async {
    await _write(
      const _LibraryState(<FeedItem>[], <_LibraryEdit>[
        _LibraryEdit('clear', null),
      ]),
    );
  });

  Future<void> setSaved(FeedItem item, bool value) => _serial(() async {
    final state = await _load();
    final items = <FeedItem>[
      if (value) item.copyWith(favorited: true),
      ...state.items.where((existing) => existing.key != item.key),
    ].take(_limit).toList();
    final edits = <_LibraryEdit>[
      ...state.edits.where((edit) => edit.item?.key != item.key),
      _LibraryEdit(value ? 'save' : 'remove', item),
    ];
    await _write(_LibraryState(items, edits));
  });

  Future<void> reconcile(LocalDatabase database) => _serial(() async {
    final state = await _load();
    for (final edit in state.edits) {
      switch (edit.operation) {
        case 'history':
          await database.addHistory(edit.item!);
        case 'clear':
          await database.clearHistory();
        case 'save':
          await database.setSaved(edit.item!, true);
        case 'remove':
          await database.setSaved(edit.item!, false);
      }
    }
    await _snapshot(database);
  });

  Future<void> snapshot(LocalDatabase database) =>
      _serial(() => _snapshot(database));

  Future<void> _snapshot(LocalDatabase database) async {
    final items = kind == 'history'
        ? await database.historyItems()
        : await database.savedItems();
    try {
      await _write(_LibraryState(items, const <_LibraryEdit>[]));
    } catch (_) {
      // The SQLite action has committed. Keep the previous recovery document
      // available; a later startup can refresh it.
    }
  }

  Future<_LibraryState> _load() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) {
      final legacy = await _preferences.getString(_legacyKey);
      if (legacy == null || legacy.isEmpty) {
        return const _LibraryState(<FeedItem>[], <_LibraryEdit>[]);
      }
      try {
        final items = listOfMaps(
          jsonDecode(legacy),
        ).map(FeedItem.fromJson).take(_limit).toList();
        return _LibraryState(items, const <_LibraryEdit>[]);
      } catch (_) {
        return const _LibraryState(<FeedItem>[], <_LibraryEdit>[]);
      }
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['items'] is! List ||
          value['edits'] is! List) {
        throw const FormatException('本地内容恢复记录无效');
      }
      final items = (value['items'] as List)
          .map((row) => FeedItem.fromJson((row as Map).cast<String, Object?>()))
          .take(_limit)
          .toList();
      final edits = (value['edits'] as List).map((row) {
        final json = (row as Map).cast<String, Object?>();
        final operation = json['operation'];
        if (!const {'history', 'clear', 'save', 'remove'}.contains(operation) ||
            (operation == 'clear') != (json['item'] == null)) {
          throw const FormatException('本地内容恢复操作无效');
        }
        return _LibraryEdit(
          operation as String,
          json['item'] == null
              ? null
              : FeedItem.fromJson(
                  (json['item'] as Map).cast<String, Object?>(),
                ),
        );
      }).toList();
      if (edits.length > 2000) throw const FormatException('本地内容恢复操作过多');
      return _LibraryState(items, edits);
    } catch (_) {
      throw const FormatException('本地内容恢复记录损坏，请先备份应用数据');
    }
  }

  Future<void> _write(_LibraryState state) {
    if (state.edits.length > 2000) {
      throw StateError('待同步的本地内容操作过多，请恢复 SQLite 后重试');
    }
    return _preferences.setString(
      _key,
      jsonEncode(<String, Object?>{
        'version': 1,
        'items': state.items.map((item) => item.toJson()).toList(),
        'edits': state.edits
            .map(
              (edit) => <String, Object?>{
                'operation': edit.operation,
                if (edit.item != null) 'item': edit.item!.toJson(),
              },
            )
            .toList(),
      }),
    );
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _tails[_key] ?? Future<void>.value();
    final next = previous.then((_) => action());
    final tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _tails[_key] = tail;
    tail.then((_) {
      if (identical(_tails[_key], tail)) _tails.remove(_key);
    });
    return next;
  }
}

class _LibraryState {
  const _LibraryState(this.items, this.edits);
  final List<FeedItem> items;
  final List<_LibraryEdit> edits;
}

class _LibraryEdit {
  const _LibraryEdit(this.operation, this.item);
  final String operation;
  final FeedItem? item;
}
