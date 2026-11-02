import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/theme.dart';

/// Colour scheme and background choices, saved on the device.
class AppearanceController extends ChangeNotifier {
  AppearanceController(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppearanceController> load() async =>
      AppearanceController(await SharedPreferences.getInstance());

  AccentPalette get palette => paletteById(_prefs.getString('accent'));
  bool get isTrueBlack => _prefs.getBool('trueBlack') ?? false;

  Future<void> setPalette(AccentPalette palette) async {
    await _prefs.setString('accent', palette.id);
    notifyListeners();
  }

  Future<void> setTrueBlack(bool value) async {
    await _prefs.setBool('trueBlack', value);
    notifyListeners();
  }
}
