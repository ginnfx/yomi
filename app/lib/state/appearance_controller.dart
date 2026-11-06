import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/theme.dart';

const double kMinTextScale = 0.85;
const double kMaxTextScale = 1.3;

const String _accentKey = 'accent';
const String _customAccentKey = 'customAccent';
const String _trueBlackKey = 'trueBlack';
const String _themeModeKey = 'themeMode';
const String _accentFromCoverKey = 'accentFromCover';
const String _textScaleKey = 'textScale';
const String _reduceMotionKey = 'reduceMotion';

/// Colour scheme, theme, text size and motion choices, saved on the device.
class AppearanceController extends ChangeNotifier {
  AppearanceController(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppearanceController> load() async =>
      AppearanceController(await SharedPreferences.getInstance());

  /// The custom colour when one was picked, otherwise the chosen preset.
  AccentPalette get palette {
    final custom = customAccent;
    return custom == null
        ? paletteById(_prefs.getString(_accentKey))
        : AccentPalette.fromColor(custom);
  }

  Color? get customAccent {
    final value = _prefs.getInt(_customAccentKey);
    return value == null ? null : Color(value);
  }

  bool get isTrueBlack => _prefs.getBool(_trueBlackKey) ?? false;

  /// Dark by default: it's the look Yomi always had.
  ThemeMode get themeMode => ThemeMode.values.firstWhere(
    (mode) => mode.name == _prefs.getString(_themeModeKey),
    orElse: () => ThemeMode.dark,
  );

  /// Whether the accent follows the cover of the song that's playing.
  bool get accentFromCover => _prefs.getBool(_accentFromCoverKey) ?? false;

  /// Multiplies the system text size.
  double get textScale => (_prefs.getDouble(_textScaleKey) ?? 1).clamp(
    kMinTextScale,
    kMaxTextScale,
  );

  bool get reduceMotion => _prefs.getBool(_reduceMotionKey) ?? false;

  Future<void> setPalette(AccentPalette palette) async {
    await _prefs.remove(_customAccentKey);
    await _prefs.setString(_accentKey, palette.id);
    notifyListeners();
  }

  Future<void> setCustomAccent(Color color) async {
    await _prefs.setInt(_customAccentKey, color.toARGB32());
    notifyListeners();
  }

  Future<void> setTrueBlack(bool value) =>
      _save(() => _prefs.setBool(_trueBlackKey, value));

  Future<void> setThemeMode(ThemeMode mode) =>
      _save(() => _prefs.setString(_themeModeKey, mode.name));

  Future<void> setAccentFromCover(bool value) =>
      _save(() => _prefs.setBool(_accentFromCoverKey, value));

  Future<void> setTextScale(double value) => _save(
    () => _prefs.setDouble(
      _textScaleKey,
      value.clamp(kMinTextScale, kMaxTextScale),
    ),
  );

  Future<void> setReduceMotion(bool value) =>
      _save(() => _prefs.setBool(_reduceMotionKey, value));

  Future<void> _save(Future<bool> Function() write) async {
    await write();
    notifyListeners();
  }
}
