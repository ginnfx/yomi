import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_update.dart';

const Duration kUpdateCheckInterval = Duration(hours: 6);

const String _lastCheckKey = 'update.lastCheckMs';
const String _latestKey = 'update.latest';
const String _dismissedKey = 'update.dismissed';

/// How this platform takes an update.
enum UpdateMode {
  androidInstall,
  macosInstall,

  /// Replaces the AppImage the app was started from.
  linuxAppImageInstall,
  openReleasePage,
  disabled,
}

enum UpdatePhase {
  idle,
  available,
  downloading,
  installing,
  readyToInstall,
  failed,
}

/// What a check the user asked for found.
enum UpdateCheckResult { available, upToDate, failed, unsupported }

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.currentVersion,
    required this.mode,
    required this.client,
    required this.prefs,
    required this.downloadDir,
    required this.install,
    required this.openPage,
    this.now = DateTime.now,
  });

  final AppVersion currentVersion;
  final UpdateMode mode;
  final UpdateClient client;
  final SharedPreferences prefs;
  final Directory downloadDir;
  final Future<void> Function(File package) install;
  final Future<void> Function(Uri url) openPage;
  final DateTime Function() now;

  UpdatePhase _phase = UpdatePhase.idle;
  ReleaseInfo? _release;
  double? _progress;
  String? _errorMessage;
  File? _verifiedPackage;
  bool _isChecking = false;

  UpdatePhase get phase => _phase;
  ReleaseInfo? get release => _release;

  /// Download progress from 0 to 1, or null when the size is unknown.
  double? get progress => _progress;
  String? get errorMessage => _errorMessage;

  String? get assetName => switch (mode) {
    UpdateMode.androidInstall => kApkAssetName,
    UpdateMode.macosInstall => kMacAssetName,
    UpdateMode.linuxAppImageInstall => kLinuxAppImageAssetName,
    _ => null,
  };

  bool get isDesktopInstall =>
      mode == UpdateMode.macosInstall ||
      mode == UpdateMode.linuxAppImageInstall;

  bool get _isBusy =>
      _phase == UpdatePhase.installing ||
      _phase == UpdatePhase.downloading ||
      _phase == UpdatePhase.readyToInstall;

  /// Safe to call often: GitHub is contacted at most every [kUpdateCheckInterval].
  Future<void> check() async {
    if (mode == UpdateMode.disabled || _isChecking || _isBusy) return;
    _isChecking = true;
    try {
      final latest = await _latestRelease();
      if (!_isBusy && !_isFailureStillCurrent(latest)) _offer(latest);
    } finally {
      _isChecking = false;
    }
  }

  /// The user asked: contacts GitHub now and offers even a dismissed version.
  Future<UpdateCheckResult> checkNow() async {
    if (mode == UpdateMode.disabled) return UpdateCheckResult.unsupported;
    if (_isBusy) return UpdateCheckResult.available;
    final ReleaseInfo latest;
    try {
      latest = await client.fetchLatest();
    } on Exception catch (error) {
      debugPrint('Update check failed: $error');
      return UpdateCheckResult.failed;
    }
    await prefs.setString(_latestKey, jsonEncode(latest.toJson()));
    await prefs.setInt(_lastCheckKey, now().millisecondsSinceEpoch);
    if (prefs.getString(_dismissedKey) == latest.version.toString()) {
      await prefs.remove(_dismissedKey);
    }
    if (_isBusy) return UpdateCheckResult.available;
    _offer(latest);
    return _phase == UpdatePhase.available
        ? UpdateCheckResult.available
        : UpdateCheckResult.upToDate;
  }

  Future<void> startUpdate() async {
    final release = _release;
    if (release == null ||
        mode == UpdateMode.disabled ||
        _phase == UpdatePhase.downloading ||
        _phase == UpdatePhase.installing) {
      return;
    }
    if (mode == UpdateMode.openReleasePage) {
      await _openReleasePage(release);
      return;
    }
    final existing = _verifiedPackage;
    if (existing != null) {
      await _launchInstaller(existing);
      return;
    }
    await _downloadAndInstall(release);
  }

  Future<void> dismiss() async {
    final release = _release;
    if (release == null ||
        mode == UpdateMode.disabled ||
        _phase == UpdatePhase.downloading ||
        _phase == UpdatePhase.installing) {
      return;
    }
    await prefs.setString(_dismissedKey, release.version.toString());
    _release = null;
    _verifiedPackage = null;
    _errorMessage = null;
    _setPhase(UpdatePhase.idle);
  }

  // Keep showing the error unless there is a different release to try instead.
  bool _isFailureStillCurrent(ReleaseInfo? latest) =>
      _phase == UpdatePhase.failed &&
      latest?.version.toString() == _release?.version.toString();

  Future<ReleaseInfo?> _latestRelease() async {
    final lastCheck = prefs.getInt(_lastCheckKey);
    if (lastCheck != null) {
      final age = now().difference(
        DateTime.fromMillisecondsSinceEpoch(lastCheck),
      );
      if (!age.isNegative && age < kUpdateCheckInterval)
        return _cachedRelease();
    }
    try {
      final latest = await client.fetchLatest();
      await prefs.setString(_latestKey, jsonEncode(latest.toJson()));
      await prefs.setInt(_lastCheckKey, now().millisecondsSinceEpoch);
      return latest;
    } on Exception catch (error) {
      // Background check: nothing for the user to act on, and the next one retries.
      debugPrint('Update check failed: $error');
      return _cachedRelease();
    }
  }

  ReleaseInfo? _cachedRelease() {
    final cached = prefs.getString(_latestKey);
    if (cached == null) return null;
    try {
      final json = jsonDecode(cached);
      return json is Map<String, dynamic> ? ReleaseInfo.tryParse(json) : null;
    } on FormatException catch (error) {
      debugPrint('Ignoring corrupt update cache: $error');
      return null;
    }
  }

  void _offer(ReleaseInfo? latest) {
    if (latest == null || !_shouldOffer(latest)) {
      _release = null;
      _setPhase(UpdatePhase.idle);
      return;
    }
    _release = latest;
    _verifiedPackage = null;
    _errorMessage = null;
    _setPhase(UpdatePhase.available);
  }

  bool _shouldOffer(ReleaseInfo latest) {
    if (!latest.version.isNewerThan(currentVersion)) return false;
    if (prefs.getString(_dismissedKey) == latest.version.toString()) {
      return false;
    }
    return assetName == null || latest.canInstall(assetName!);
  }

  Future<void> _openReleasePage(ReleaseInfo release) async {
    try {
      await openPage(release.pageUrl);
    } on Exception catch (error) {
      debugPrint('Could not open release page: $error');
      _fail("Yomi couldn't open the download page.");
    }
  }

  Future<void> _downloadAndInstall(ReleaseInfo release) async {
    _errorMessage = null;
    _progress = null;
    _setPhase(UpdatePhase.downloading);
    final name = assetName!;
    final suffix = mode == UpdateMode.androidInstall
        ? '.apk'
        : name.substring(4);
    final target = File('${downloadDir.path}/Yomi-${release.version}$suffix');
    try {
      await _removeOtherFiles(target);
      final hash = await client.fetchChecksum(
        release.assetUrl('$name.sha256')!,
      );
      final package = await client.downloadVerified(
        release.assetUrl(name)!,
        expectedSha256: hash,
        destination: target,
        onProgress: _reportProgress,
      );
      _verifiedPackage = package;
      _setPhase(UpdatePhase.readyToInstall);
      await _launchInstaller(package);
    } on UpdateException catch (error) {
      debugPrint('Update failed: $error');
      _fail(error.message);
    } on Exception catch (error) {
      debugPrint('Update failed: $error');
      _fail("Yomi couldn't download the update. Try again later.");
    }
  }

  Future<void> _launchInstaller(File package) async {
    _setPhase(UpdatePhase.installing);
    try {
      await install(package);
      _setPhase(UpdatePhase.readyToInstall);
    } on Exception catch (error) {
      debugPrint('Could not start the installer: $error');
      // The file may be gone (the system can clear caches), so retry from the start.
      _verifiedPackage = null;
      _fail(
        error is UpdateException
            ? error.message
            : isDesktopInstall
            ? "Yomi couldn't install the update. Try again."
            : "Yomi couldn't open the Android installer.",
      );
    }
  }

  Future<void> _removeOtherFiles(File keep) async {
    if (!await downloadDir.exists()) return;
    await for (final entry in downloadDir.list()) {
      if (entry is File && entry.path != keep.path) await entry.delete();
    }
  }

  void _reportProgress(double? fraction) {
    final hasVisibleChange =
        fraction == null ||
        _progress == null ||
        (fraction * 100).floor() != (_progress! * 100).floor();
    _progress = fraction;
    if (hasVisibleChange) notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    _setPhase(UpdatePhase.failed);
  }

  void _setPhase(UpdatePhase phase) {
    _phase = phase;
    notifyListeners();
  }
}
