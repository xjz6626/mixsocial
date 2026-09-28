import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/search_history.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FailingPreferences extends SharedPreferencesAsync {
  _FailingPreferences(this.shouldFailWrites);

  final bool Function() shouldFailWrites;

  @override
  Future<void> setStringList(String key, List<String> value) async {
    if (shouldFailWrites()) throw StateError('disk full');
    await super.setStringList(key, value);
  }
}

void main() {
  late SharedPreferencesAsync preferences;
  late SearchHistoryStore history;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    preferences = SharedPreferencesAsync();
    history = SearchHistoryStore(preferences);
  });

  test('normalizes queries and keeps the latest spelling first', () async {
    await history.add(SourceId.xhs, '  Flutter  ');
    await history.add(SourceId.xhs, '旅行');
    await history.add(SourceId.xhs, 'flutter');
    await history.add(SourceId.xhs, '  ');

    expect(await history.read(SourceId.xhs), <String>['flutter', '旅行']);
    expect(await SearchHistoryStore(preferences).read(SourceId.xhs), <String>[
      'flutter',
      '旅行',
    ]);
  });

  test('retains the newest twenty queries during concurrent writes', () async {
    await Future.wait(
      List<Future<List<String>>>.generate(
        25,
        (index) => history.add(SourceId.all, 'query $index'),
      ),
    );

    final restored = await history.read(SourceId.all);
    expect(restored, hasLength(20));
    expect(restored.first, 'query 24');
    expect(restored.last, 'query 5');
  });

  test('delete and clear affect only the selected source', () async {
    for (final source in SourceId.values) {
      await history.add(source, 'Flutter');
      await history.add(source, '旅行');
    }
    await history.remove(SourceId.xhs, '  FLUTTER  ');
    expect(await history.read(SourceId.xhs), <String>['旅行']);
    await history.clear(SourceId.xhs);
    expect(await history.read(SourceId.xhs), isEmpty);
    expect(await history.read(SourceId.tieba), <String>['旅行', 'Flutter']);
    expect(await history.read(SourceId.all), <String>['旅行', 'Flutter']);
  });

  test('queued clear and add preserve the order of user actions', () async {
    await history.add(SourceId.tieba, 'old');
    final pendingAdd = history.add(SourceId.tieba, 'discard');
    final pendingClear = history.clear(SourceId.tieba);
    final pendingNew = history.add(SourceId.tieba, 'keep');
    await Future.wait(<Future<List<String>>>[
      pendingAdd,
      pendingClear,
      pendingNew,
    ]);

    expect(await history.read(SourceId.tieba), <String>['keep']);
  });

  test('damaged saved data is ignored and can be replaced', () async {
    await preferences.setString('search.history.xhs', 'not a list');
    expect(await history.read(SourceId.xhs), isEmpty);
    await history.add(SourceId.xhs, '恢复');
    expect(await history.read(SourceId.xhs), <String>['恢复']);

    await preferences.setStringList('search.history.xhs', <String>[
      '',
      '   ',
      ' Flutter ',
      'flutter',
      '旅行',
    ]);
    expect(await history.read(SourceId.xhs), <String>['Flutter', '旅行']);
  });

  test('a failed write does not poison later operations', () async {
    var failWrites = true;
    final failing = _FailingPreferences(() => failWrites);
    final store = SearchHistoryStore(failing);
    await expectLater(store.add(SourceId.xhs, 'lost'), throwsStateError);
    failWrites = false;
    await store.add(SourceId.xhs, 'saved');

    expect(await store.read(SourceId.xhs), <String>['saved']);
  });
}
