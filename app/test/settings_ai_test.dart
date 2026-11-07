import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/state/settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('AI helps everywhere until each place is switched off', () async {
    final settings = await SettingsController.load();

    expect(settings.isAiSearchOn, isTrue);
    expect(settings.isDiscoverOn, isTrue);
    expect(settings.sendsTasteToAssistant, isTrue);
  });

  test('switching AI search off is remembered', () async {
    final settings = await SettingsController.load();

    await settings.setAiSearchOn(false);

    expect(settings.isAiSearchOn, isFalse);
    expect((await SettingsController.load()).isAiSearchOn, isFalse);
  });

  test(
    'signing out forgets the AI choices with the rest of the person',
    () async {
      final settings = await SettingsController.load();
      await settings.setDiscoverOn(false);
      await settings.setSendsTasteToAssistant(false);

      await settings.clearPersonal();

      expect(settings.isDiscoverOn, isTrue);
      expect(settings.sendsTasteToAssistant, isTrue);
    },
  );
}
