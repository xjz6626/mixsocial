import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ReadingPreferences {
  const ReadingPreferences({this.fontSize = 16, this.lineHeight = 1.6});

  final double fontSize;
  final double lineHeight;

  ReadingPreferences copyWith({double? fontSize, double? lineHeight}) =>
      ReadingPreferences(
        fontSize: (fontSize ?? this.fontSize).clamp(12, 26),
        lineHeight: (lineHeight ?? this.lineHeight).clamp(1.2, 2.2),
      );
}

class ReadingPreferencesStore {
  ReadingPreferencesStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  static const _key = 'reading.preferences.v1';

  Future<ReadingPreferences> read() async {
    try {
      final raw = await _preferences.getString(_key);
      if (raw == null) return const ReadingPreferences();
      final value = jsonDecode(raw);
      if (value is! Map) return const ReadingPreferences();
      final size = value['fontSize'];
      final height = value['lineHeight'];
      return ReadingPreferences(
        fontSize: size is num && size.isFinite
            ? size.toDouble().clamp(12, 26)
            : 16,
        lineHeight: height is num && height.isFinite
            ? height.toDouble().clamp(1.2, 2.2)
            : 1.6,
      );
    } on FormatException {
      return const ReadingPreferences();
    } on TypeError {
      return const ReadingPreferences();
    }
  }

  Future<void> save(ReadingPreferences value) => _preferences.setString(
    _key,
    jsonEncode(<String, double>{
      'fontSize': value.fontSize.isFinite ? value.fontSize.clamp(12, 26) : 16,
      'lineHeight': value.lineHeight.isFinite
          ? value.lineHeight.clamp(1.2, 2.2)
          : 1.6,
    }),
  );
}
