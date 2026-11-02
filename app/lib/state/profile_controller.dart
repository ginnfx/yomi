import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Nickname and profile picture. The picture is copied into the app's own folder,
/// so it keeps working even if the original photo is deleted.
class ProfileController extends ChangeNotifier {
  ProfileController(this._prefs, this._directory);

  final SharedPreferences _prefs;
  final Directory _directory;

  static Future<ProfileController> load(Directory directory) async {
    await directory.create(recursive: true);
    return ProfileController(await SharedPreferences.getInstance(), directory);
  }

  String get nickname => _prefs.getString('nickname') ?? '';

  /// What to call the user: the nickname if set, otherwise the account name.
  String displayName(String username) =>
      nickname.trim().isEmpty ? username : nickname.trim();

  File? get avatarFile {
    final path = _prefs.getString('avatarPath');
    if (path == null) return null;
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  Future<void> setNickname(String value) async {
    await _prefs.setString('nickname', value.trim());
    notifyListeners();
  }

  Future<void> setAvatar(File source) async {
    final extension = source.path.contains('.')
        ? source.path.split('.').last.toLowerCase()
        : 'jpg';
    final target = File(
      '${_directory.path}/avatar-${DateTime.now().millisecondsSinceEpoch}.$extension',
    );
    await source.copy(target.path);
    await _deleteOldAvatar();
    await _prefs.setString('avatarPath', target.path);
    notifyListeners();
  }

  Future<void> clearAvatar() async {
    await _deleteOldAvatar();
    await _prefs.remove('avatarPath');
    notifyListeners();
  }

  Future<void> _deleteOldAvatar() async {
    final old = _prefs.getString('avatarPath');
    if (old == null) return;
    final file = File(old);
    if (await file.exists()) await file.delete();
  }
}
