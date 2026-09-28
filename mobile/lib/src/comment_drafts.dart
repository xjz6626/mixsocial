import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class CommentDraft {
  const CommentDraft({required this.body, this.unconfirmed = false});
  final String body;
  final bool unconfirmed;
}

class CommentDraftStore {
  CommentDraftStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  static final Map<String, Future<void>> _pending = <String, Future<void>>{};

  static String draftKey(ContentRef content, {ContentRef? target}) =>
      '${content.source.id}:${Uri.encodeComponent(content.id)}:${target == null ? 'comment' : 'reply:${Uri.encodeComponent(target.id)}'}';

  Future<CommentDraft?> read(String key) => _serialize(key, () => _read(key));

  Future<void> save(String key, CommentDraft draft) =>
      _serialize(key, () async {
        if (draft.body.isEmpty) {
          await _preferences.remove(_key(key));
          return;
        }
        await _preferences.setString(
          _key(key),
          jsonEncode(<String, Object?>{
            'body': draft.body,
            'unconfirmed': draft.unconfirmed,
          }),
        );
      });

  /// Only remove the confirmed submission, never a later edit in another route.
  Future<void> clear(String key, {String? expectedBody}) =>
      _serialize(key, () async {
        final value = await _read(key);
        if (expectedBody == null || value?.body.trim() == expectedBody.trim()) {
          await _preferences.remove(_key(key));
        }
      });

  Future<CommentDraft?> _read(String key) async {
    try {
      final raw = await _preferences.getString(_key(key));
      if (raw == null) return null;
      final value = jsonDecode(raw);
      if (value is! Map || value['body'] is! String) return null;
      return CommentDraft(
        body: value['body'] as String,
        unconfirmed: value['unconfirmed'] == true,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  String _key(String key) => 'comment.draft.v1.$key';

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
