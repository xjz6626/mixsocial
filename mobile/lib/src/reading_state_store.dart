import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A concrete page/comment anchor, never a percentage of a changing thread.
class ReadingState {
  const ReadingState({
    this.page = 1,
    this.offset = 0,
    this.floor = 0,
    this.anchorId = '',
    this.reverse = false,
    this.onlyOriginalPoster = false,
    this.completed = false,
    required this.updatedAt,
  });

  final int page;
  final double offset;
  final int floor;
  final String anchorId;
  final bool reverse;
  final bool onlyOriginalPoster;
  final bool completed;
  final DateTime updatedAt;

  String get label => completed
      ? '已读'
      : floor > 0
      ? '读到第 $page 页 · $floor 楼'
      : page > 1
      ? '读到第 $page 页'
      : '阅读中';

  ReadingState copyWith({bool? completed}) => ReadingState(
    page: page,
    offset: offset,
    floor: floor,
    anchorId: anchorId,
    reverse: reverse,
    onlyOriginalPoster: onlyOriginalPoster,
    completed: completed ?? this.completed,
    updatedAt: DateTime.now(),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'page': page.clamp(1, 100000),
    'offset': offset.isFinite ? offset.clamp(-10000000, 10000000) : 0,
    'floor': floor.clamp(0, 10000000),
    'anchorId': anchorId,
    'reverse': reverse,
    'onlyOriginalPoster': onlyOriginalPoster,
    'completed': completed,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory ReadingState.fromJson(Map<String, dynamic> value) {
    final offset = value['offset'];
    return ReadingState(
      page: value['page'] is int ? (value['page'] as int).clamp(1, 100000) : 1,
      offset: offset is num && offset.isFinite
          ? offset.toDouble().clamp(-10000000, 10000000)
          : 0,
      floor: value['floor'] is int
          ? (value['floor'] as int).clamp(0, 10000000)
          : 0,
      anchorId: value['anchorId'] is String ? value['anchorId'] as String : '',
      reverse: value['reverse'] == true,
      onlyOriginalPoster: value['onlyOriginalPoster'] == true,
      completed: value['completed'] == true,
      updatedAt:
          DateTime.tryParse(value['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class ReadingStateStore {
  ReadingStateStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  static const _prefix = 'reading.position.v1.';
  // Shared across routes/store instances. Each item is a separate preference,
  // so a library completion toggle cannot overwrite another thread's progress.
  static final Map<String, Future<void>> _pending = <String, Future<void>>{};

  Future<ReadingState?> get(String itemKey) =>
      _serialize(itemKey, () => _read(itemKey));

  Future<Map<String, ReadingState>> all() async {
    final result = <String, ReadingState>{};
    for (final key in await _preferences.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final itemKey = Uri.decodeComponent(key.substring(_prefix.length));
      final value = await get(itemKey);
      if (value != null) result[itemKey] = value;
    }
    return result;
  }

  Future<void> save(String itemKey, ReadingState value) =>
      _serialize(itemKey, () async {
        if (itemKey.trim().isEmpty) return;
        final previous = await _read(itemKey);
        // Scroll position updates do not undo an explicit library completion.
        await _preferences.setString(
          _key(itemKey),
          jsonEncode(
            value
                .copyWith(completed: previous?.completed ?? value.completed)
                .toJson(),
          ),
        );
      });

  Future<void> setCompleted(String itemKey, bool value) =>
      _serialize(itemKey, () async {
        if (itemKey.trim().isEmpty) return;
        final previous =
            await _read(itemKey) ?? ReadingState(updatedAt: DateTime.now());
        await _preferences.setString(
          _key(itemKey),
          jsonEncode(previous.copyWith(completed: value).toJson()),
        );
      });

  Future<ReadingState?> _read(String itemKey) async {
    try {
      final raw = await _preferences.getString(_key(itemKey));
      if (raw == null) return null;
      final value = jsonDecode(raw);
      return value is Map<String, dynamic>
          ? ReadingState.fromJson(value)
          : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  String _key(String itemKey) => '$_prefix${Uri.encodeComponent(itemKey)}';

  Future<T> _serialize<T>(String key, Future<T> Function() action) {
    final previous = _pending[key];
    final next = previous == null ? action() : previous.then((_) => action());
    final tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _pending[key] = tail;
    tail.then((_) {
      if (identical(_pending[key], tail)) _pending.remove(key);
    });
    return next;
  }
}
