import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class LocalSettings {
  LocalSettings(this._preferences);

  final SharedPreferencesAsync _preferences;

  static Future<LocalSettings> create() async =>
      LocalSettings(SharedPreferencesAsync());

  Future<FeedLayout> layoutFor(SourceId source) async {
    final saved = await _preferences.getString('layout.${source.id}');
    if (saved == FeedLayout.list.name) return FeedLayout.list;
    if (saved == FeedLayout.masonry.name) return FeedLayout.masonry;
    return source == SourceId.tieba ? FeedLayout.list : FeedLayout.masonry;
  }

  Future<void> setLayout(SourceId source, FeedLayout layout) =>
      _preferences.setString('layout.${source.id}', layout.name);

  Future<double> scrollOffsetFor(SourceId source) async {
    final saved = await _preferences.getDouble('scroll.${source.id}');
    if (saved == null || !saved.isFinite || saved < 0) return 0;
    return saved;
  }

  Future<void> setScrollOffset(SourceId source, double offset) =>
      _preferences.setDouble(
        'scroll.${source.id}',
        offset.isFinite && offset > 0 ? offset : 0,
      );

  Future<Set<String>> blockedProfiles() async =>
      (await _preferences.getStringList('relationships.blocked') ??
              const <String>[])
          .toSet();

  Future<Set<String>> followingProfiles() async =>
      (await _preferences.getStringList('relationships.following') ??
              const <String>[])
          .toSet();

  Future<void> setBlocked(ProfileRef profile, bool value) async {
    final profiles = await blockedProfiles();
    value ? profiles.add(profile.key) : profiles.remove(profile.key);
    await _preferences.setStringList(
      'relationships.blocked',
      profiles.toList()..sort(),
    );
  }

  Future<void> setFollowing(ProfileRef profile, bool value) async {
    final profiles = await followingProfiles();
    value ? profiles.add(profile.key) : profiles.remove(profile.key);
    await _preferences.setStringList(
      'relationships.following',
      profiles.toList()..sort(),
    );
  }
}
