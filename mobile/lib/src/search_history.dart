import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Recent queries are private to each selected source, including mixed search.
class SearchHistoryStore {
  SearchHistoryStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const int limit = 20;

  final SharedPreferencesAsync _preferences;
  final Map<SourceId, Future<void>> _pending = <SourceId, Future<void>>{};

  Future<List<String>> read(SourceId source) =>
      _serialize(source, () => _read(source));

  Future<List<String>> add(SourceId source, String value) =>
      _serialize(source, () async {
        final query = value.trim();
        final previous = await _read(source);
        if (query.isEmpty) return previous;
        final queries = _normalize(<String>[query, ...previous]);
        await _preferences.setStringList(_key(source), queries);
        return queries;
      });

  Future<List<String>> remove(SourceId source, String value) =>
      _serialize(source, () async {
        final query = value.trim().toLowerCase();
        final queries = (await _read(
          source,
        )).where((item) => item.toLowerCase() != query).toList(growable: false);
        await _preferences.setStringList(_key(source), queries);
        return List<String>.unmodifiable(queries);
      });

  Future<List<String>> clear(SourceId source) => _serialize(source, () async {
    await _preferences.remove(_key(source));
    return const <String>[];
  });

  Future<List<String>> _read(SourceId source) async {
    try {
      return _normalize(
        await _preferences.getStringList(_key(source)) ?? const <String>[],
      );
    } on TypeError {
      // An old or damaged preference must not make history unusable.
      return const <String>[];
    } on FormatException {
      return const <String>[];
    }
  }

  List<String> _normalize(Iterable<String> values) {
    final seen = <String>{};
    return List<String>.unmodifiable(
      values
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty && seen.add(value.toLowerCase()))
          .take(limit),
    );
  }

  Future<T> _serialize<T>(SourceId source, Future<T> Function() action) {
    final previous = _pending[source] ?? Future<void>.value();
    final next = previous.then((_) => action());
    // A failed write is reported to its caller but never blocks later changes.
    _pending[source] = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return next;
  }

  String _key(SourceId source) => 'search.history.${source.id}';
}
