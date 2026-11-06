import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/state/appearance_controller.dart';
import 'package:yomi/ui/appearance_scope.dart';
import 'package:yomi/ui/theme.dart';

void main() {
  tearDown(() => YomiColors.useBrightness(Brightness.dark));

  Future<AppearanceController> pumpApp(
    WidgetTester tester,
    Map<String, Object> saved,
    WidgetBuilder probe,
  ) async {
    SharedPreferences.setMockInitialValues(saved);
    final look = AppearanceController(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: look,
        child: Consumer<AppearanceController>(
          builder: (context, look, _) => MaterialApp(
            theme: buildYomiTheme(look.palette, brightness: Brightness.light),
            darkTheme: buildYomiTheme(look.palette),
            themeMode: look.themeMode,
            builder: (context, child) => AppearanceScope(child: child!),
            home: Builder(builder: probe),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return look;
  }

  testWidgets('the light theme turns text dark', (tester) async {
    // Act
    await pumpApp(tester, {'themeMode': 'light'}, (_) => const SizedBox());

    // Assert
    expect(YomiColors.isLight, isTrue);
  });

  testWidgets('switching back to dark repaints in dark colours', (
    tester,
  ) async {
    // Arrange
    final look = await pumpApp(tester, {
      'themeMode': 'light',
    }, (_) => const SizedBox());

    // Act
    await look.setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();

    // Assert
    expect(YomiColors.isLight, isFalse);
  });

  testWidgets('pages get the chosen text size and motion choice', (
    tester,
  ) async {
    // Arrange
    late double scale;
    late Duration motion;

    // Act
    await pumpApp(tester, {'textScale': 1.2, 'reduceMotion': true}, (context) {
      scale = MediaQuery.textScalerOf(context).scale(1);
      motion = context.motion(YomiMotion.standard);
      return const SizedBox();
    });

    // Assert
    expect(scale, closeTo(1.2, 0.001));
    expect(motion, Duration.zero);
  });

  test('a dark cover colour becomes a bright accent', () {
    // Act
    final accent = accentFromCoverColor(const Color(0xFF1A0A30));

    // Assert
    expect(HSLColor.fromColor(accent).lightness, closeTo(0.62, 0.01));
  });
}
