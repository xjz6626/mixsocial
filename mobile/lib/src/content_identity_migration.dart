import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// Migrate only identities supported by a stored content payload. Ambiguous
/// legacy state is retained, never assigned to an arbitrary content type.
Future<void> migrateContentPreferences(
  SharedPreferencesAsync preferences,
  Iterable<FeedItem> stored,
) async {
  final mappings = <String, Set<String>>{};
  void add(ContentRef ref) {
    if (ref.source == SourceId.zhihu) {
      mappings.putIfAbsent(ref.legacyKey, () => {}).add(ref.key);
    }
  }

  for (final item in stored) {
    add(item.ref);
  }
  void collect(Object? value) {
    if (value is List) {
      for (final child in value) {
        collect(child);
      }
    }
    if (value is Map) {
      if (value['ref'] is Map) add(ContentRef.fromJson(mapOf(value['ref'])));
      for (final child in value.values) {
        collect(child);
      }
    }
  }

  final keys = await preferences.getKeys();
  for (final key in keys.where(
    (key) => key.startsWith('library.') || key.startsWith('cache.'),
  )) {
    try {
      final value = await preferences.getString(key);
      if (value != null) collect(jsonDecode(value));
    } on FormatException {
      /* Leave damaged records to their recovery path. */
    } on TypeError {
      /* Not a JSON preference. */
    }
  }
  for (final entry in mappings.entries.where(
    (entry) => entry.value.length == 1,
  )) {
    final next = entry.value.single;
    final oldPosition = 'reading.position.v1.${Uri.encodeComponent(entry.key)}';
    final nextPosition = 'reading.position.v1.${Uri.encodeComponent(next)}';
    final position = await preferences.getString(oldPosition);
    if (position != null && await preferences.getString(nextPosition) == null) {
      await preferences.setString(nextPosition, position);
    }
    if (position != null) await preferences.remove(oldPosition);
    // Do not overwrite a newer typed draft or resurrect a cleared draft later.
    final oldPrefix = 'comment.draft.v1.${entry.key}:';
    for (final key in keys.where((key) => key.startsWith(oldPrefix))) {
      final newKey =
          'comment.draft.v1.$next:${key.substring(oldPrefix.length)}';
      final value = await preferences.getString(key);
      if (value != null && await preferences.getString(newKey) == null) {
        await preferences.setString(newKey, value);
      }
      if (value != null) await preferences.remove(key);
    }
  }
}
