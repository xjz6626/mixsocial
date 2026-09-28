import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_filters.dart';

/// Local preferences only: pinning does not change platform relationships.
class ForumPreferencesStore {
  ForumPreferencesStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _preferences;
  Future<void>? _writes;
  static const _key = 'forums.preferences.v1';

  Future<Map<String, Object?>> _read() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return <String, Object?>{};
    final value = jsonDecode(raw);
    if (value is! Map<String, Object?>) throw const FormatException('贴吧设置格式无效');
    return value;
  }

  Future<List<String>> pinnedForums() async {
    final raw = (await _read())['pinned'];
    return raw is List
        ? raw
              .whereType<String>()
              .map(normalizeForumName)
              .where((v) => v.isNotEmpty)
              .toSet()
              .toList()
        : <String>[];
  }

  Future<int> sortFor(String forum) async {
    final sorts = (await _read())['sorts'];
    return sorts is Map && sorts[normalizeForumName(forum)] == 1 ? 1 : 0;
  }

  Future<void> setPinned(String forum, bool value) => _change((data) {
    final name = normalizeForumName(forum);
    if (name.isEmpty) throw ArgumentError('吧名不能为空');
    final names = (data['pinned'] as List? ?? <Object>[])
        .whereType<String>()
        .toSet();
    value ? names.add(name) : names.remove(name);
    if (names.length > 100) throw StateError('最多置顶100个贴吧');
    data['pinned'] = names.toList();
  });

  Future<void> setSort(String forum, int value) => _change((data) {
    if (value != 0 && value != 1) throw ArgumentError('不支持的排序方式');
    final name = normalizeForumName(forum);
    if (name.isEmpty) throw ArgumentError('吧名不能为空');
    final sorts = Map<String, Object?>.from(
      data['sorts'] as Map? ?? <String, Object?>{},
    );
    sorts.remove(name);
    sorts[name] = value;
    while (sorts.length > 300) {
      sorts.remove(sorts.keys.first);
    }
    data['sorts'] = sorts;
  });

  Future<void> _change(void Function(Map<String, Object?>) update) {
    final next = (_writes ?? Future<void>.value()).then((_) async {
      final data = await _read();
      update(data);
      await _preferences.setString(_key, jsonEncode(data));
    });
    _writes = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}
