import 'package:flutter_test/flutter_test.dart';
import 'package:mixsocial_mobile/src/app_controller.dart';
import 'package:mixsocial_mobile/src/design_system.dart';
import 'package:mixsocial_mobile/src/device_transfer_service.dart';
import 'package:mixsocial_mobile/src/local_settings.dart';
import 'package:mixsocial_mobile/src/models.dart';
import 'package:mixsocial_mobile/src/tieba_source.dart';
import 'package:mixsocial_mobile/src/xhs_web_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Xhs implements XhsWebSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unselected account must not be accessed');
}

class _Tieba implements TiebaSource {
  int exports = 0;
  @override
  Future<String?> exportCredentialForTransfer() async {
    exports++;
    return 'BDUSS=sample';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'excluded accounts are not read and excluded preferences do not overwrite receiver',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final prefs = SharedPreferencesAsync();
      final settings = LocalSettings(prefs);
      final tieba = _Tieba();
      final controller = MixsocialController(
        xhs: _Xhs(),
        tieba: tieba,
        settings: settings,
      );
      addTearDown(controller.dispose);
      await settings.setThemePreference(AppThemePreference.dark);
      await settings.setSourceWeight(SourceId.tieba, 3);
      const blocked = Author(
        ref: ProfileRef(source: SourceId.zhihu, id: 'blocked'),
        id: 'blocked',
        name: '作者',
      );
      await settings.setAuthorBlocked(blocked, true);
      final service = DeviceTransferService(controller, preferences: prefs);
      final payload = await service.createPayload(
        includeLibrary: false,
        includePreferences: false,
        accounts: {},
      );
      expect(payload.accountLabels, isEmpty);
      expect(payload.localItemCount, 0);
      expect(payload.blockedForums, isEmpty);
      expect(payload.blockedAuthors, isEmpty);
      expect(payload.theme, AppThemePreference.system);
      await service.importPayload(payload);
      expect(await settings.themePreference(), AppThemePreference.dark);
      expect((await settings.sourceWeights())[SourceId.tieba], 3);
      expect(tieba.exports, 0);
      final selected = await service.createPayload(
        includeLibrary: false,
        accounts: {SourceId.tieba},
      );
      expect(selected.accountLabels, ['贴吧']);
      expect(selected.blockedAuthors.single.ref.key, blocked.ref.key);
      expect(selected.sourceWeights[SourceId.tieba], 3);
      expect(tieba.exports, 1);
    },
  );
}
