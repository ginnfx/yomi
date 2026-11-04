import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int kMaxBioLength = 160;

/// Nickname, bio, banner and profile picture. Pictures are copied into the app's
/// own folder, so they keep working even if the original photo is deleted.
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

  String get bio => _prefs.getString('bio') ?? '';

  Future<void> setBio(String value) async {
    final trimmed = value.trim();
    await _prefs.setString(
      'bio',
      trimmed.length > kMaxBioLength
          ? trimmed.substring(0, kMaxBioLength)
          : trimmed,
    );
    notifyListeners();
  }

  File? get bannerFile {
    final path = _prefs.getString('bannerPath');
    if (path == null) return null;
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  Future<void> setBanner(File source) async {
    final target = File(
      '${_directory.path}/banner-${DateTime.now().millisecondsSinceEpoch}${_extensionOf(source)}',
    );
    await source.copy(target.path);
    await _deleteFileAt('bannerPath');
    await _prefs.setString('bannerPath', target.path);
    notifyListeners();
  }

  Future<void> clearBanner() async {
    await _deleteFileAt('bannerPath');
    await _prefs.remove('bannerPath');
    notifyListeners();
  }

  static String _extensionOf(File file) => file.path.contains('.')
      ? '.${file.path.split('.').last.toLowerCase()}'
      : '.jpg';

  Future<void> _deleteFileAt(String key) async {
    final old = _prefs.getString(key);
    if (old == null) return;
    final file = File(old);
    if (await file.exists()) await file.delete();
  }

  Future<void> setNickname(String value) async {
    await _prefs.setString('nickname', value.trim());
    notifyListeners();
  }

  Future<void> setAvatar(File source) async {
    final target = File(
      '${_directory.path}/avatar-${DateTime.now().millisecondsSinceEpoch}${_extensionOf(source)}',
    );
    await source.copy(target.path);
    await _deleteFileAt('avatarPath');
    await _prefs.setString('avatarPath', target.path);
    notifyListeners();
  }

  Future<void> clearAvatar() async {
    await _deleteFileAt('avatarPath');
    await _prefs.remove('avatarPath');
    notifyListeners();
  }
}
