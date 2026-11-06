import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/state/appearance_controller.dart';
import 'package:yomi/ui/theme.dart';

Future<AppearanceController> controller([
  Map<String, Object> saved = const {},
]) async {
  SharedPreferences.setMockInitialValues(saved);
  return AppearanceController(await SharedPreferences.getInstance());
}

void main() {
  tearDown(() => YomiColors.useBrightness(Brightness.dark));

  group('defaults keep the look people already have', () {
    test('dark, green, normal text, full motion', () async {
      // Act
      final look = await controller();

      // Assert
      expect(look.themeMode, ThemeMode.dark);
      expect(look.palette.id, 'green');
      expect(look.textScale, 1);
      expect(look.reduceMotion, isFalse);
      expect(look.accentFromCover, isFalse);
    });
  });

  test('theme mode is remembered', () async {
    // Arrange
    final look = await controller();

    // Act
    await look.setThemeMode(ThemeMode.light);
    final relaunched = AppearanceController(
      await SharedPreferences.getInstance(),
    );

    // Assert
    expect(relaunched.themeMode, ThemeMode.light);
  });

  group('custom accent', () {
    test('replaces the preset and is remembered', () async {
      // Arrange
      final look = await controller();

      // Act
      await look.setCustomAccent(const Color(0xFF3366FF));

      // Assert
      expect(look.palette.id, kCustomPaletteId);
      expect(look.palette.accent, const Color(0xFF3366FF));
    });

    test('choosing a preset again clears it', () async {
      // Arrange
      final look = await controller();
      await look.setCustomAccent(const Color(0xFF3366FF));

      // Act
      await look.setPalette(accentPalettes[1]);

      // Assert
      expect(look.palette.id, accentPalettes[1].id);
      expect(look.customAccent, isNull);
    });
  });

  test('text size stays within readable limits', () async {
    // Arrange
    final look = await controller();

    // Act
    await look.setTextScale(5);

    // Assert
    expect(look.textScale, kMaxTextScale);
  });

  test('reduce motion and cover colour switches are remembered', () async {
    // Arrange
    final look = await controller();

    // Act
    await look.setReduceMotion(true);
    await look.setAccentFromCover(true);

    // Assert
    expect(look.reduceMotion, isTrue);
    expect(look.accentFromCover, isTrue);
  });

  group('colours', () {
    test('a palette made from one colour keeps that colour as its accent', () {
      // Act
      final palette = AccentPalette.fromColor(const Color(0xFFFF8800));

      // Assert
      expect(palette.accent, const Color(0xFFFF8800));
      expect(
        HSLColor.fromColor(palette.deep).lightness,
        lessThan(HSLColor.fromColor(palette.accent).lightness),
      );
    });

    test('text turns dark on a light background', () {
      // Act
      YomiColors.useBrightness(Brightness.light);

      // Assert
      expect(YomiColors.textPrimary.computeLuminance(), lessThan(0.1));
      expect(YomiColors.background.computeLuminance(), greaterThan(0.8));
    });

    test('both themes build', () {
      // Act
      final light = buildYomiTheme(
        accentPalettes.first,
        brightness: Brightness.light,
      );
      final dark = buildYomiTheme(accentPalettes.first);

      // Assert
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
    });
  });
}
