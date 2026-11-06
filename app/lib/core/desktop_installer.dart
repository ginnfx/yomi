import 'dart:io';

import 'app_update.dart';

/// Stages a complete bundle beside the running app before handing replacement to
/// a detached helper. No elevation: system-owned installs must be moved first.
class DesktopInstaller {
  DesktopInstaller({this.beforeRestart, String? appImagePath})
    : _appImagePath = appImagePath;

  final Future<void> Function()? beforeRestart;
  final String? _appImagePath;

  /// The AppImage this app was started from; AppImages set APPIMAGE for their app.
  String get appImagePath =>
      _appImagePath ?? Platform.environment['APPIMAGE'] ?? '';

  Future<void> install(File archive) async {
    if (Platform.isLinux) return installAppImage(archive);
    final macos = Platform.isMacOS;
    if (!macos && !Platform.isLinux) {
      throw const UpdateException('Updates are unavailable on this platform.');
    }
    final executable = File(Platform.resolvedExecutable);
    final Directory target;
    if (macos) {
      target = executable.parent.parent.parent;
      if (!target.path.endsWith('.app') ||
          target.path.contains('/AppTranslocation/')) {
        throw const UpdateException(
          'Move Yomi to a writable Applications folder, then try again.',
        );
      }
    } else {
      target = executable.parent;
      // Only portable release bundles have this marker. Never replace a system
      // directory containing other applications, or a Flutter development build.
      if (!await File('${target.path}/.yomi-portable').exists()) {
        throw const UpdateException(
          'Install the portable Yomi release in your home folder to update here.',
        );
      }
    }
    final Directory staging;
    try {
      staging = await target.parent.createTemp('.yomi-update-');
    } on FileSystemException {
      throw const UpdateException(
        'Yomi needs a writable install folder. Move it to your home folder and retry.',
      );
    }
    var handedOff = false;
    try {
      await _run(
        macos ? '/usr/bin/ditto' : 'tar',
        macos
            ? ['-x', '-k', archive.path, staging.path]
            : ['-xzf', archive.path, '-C', staging.path],
      );
      final staged = Directory(
        '${staging.path}/${macos ? 'Yomi.app' : 'Yomi'}',
      );
      final binary = File(
        '${staged.path}/${macos ? 'Contents/MacOS/Yomi' : 'yomi'}',
      );
      if (!await binary.exists() ||
          (!macos && !await File('${staged.path}/.yomi-portable').exists())) {
        throw const UpdateException(
          'The update did not contain a complete Yomi app.',
        );
      }
      if (macos) {
        await _run('/usr/bin/codesign', [
          '--verify',
          '--deep',
          '--strict',
          staged.path,
        ]);
        final id = await Process.run('/usr/libexec/PlistBuddy', [
          '-c',
          'Print :CFBundleIdentifier',
          '${staged.path}/Contents/Info.plist',
        ]);
        if (id.exitCode != 0 ||
            id.stdout.toString().trim() != 'com.yomi.yomi') {
          throw const UpdateException(
            'The update did not contain the Yomi app.',
          );
        }
      } else {
        await _run('chmod', ['+x', binary.path]);
      }
      await beforeRestart?.call();
      final helper = File('${staging.path}/install.sh');
      await helper.writeAsString(desktopInstallScript);
      final log = File('${archive.parent.path}/install.log');
      // Arguments stay separate from shell source, including paths with quotes.
      await Process.start('/bin/sh', [
        helper.path,
        '$pid',
        target.path,
        staged.path,
        staging.path,
        macos ? 'macos' : 'linux',
        log.path,
      ], mode: ProcessStartMode.detached);
      handedOff = true;
      exit(0);
    } finally {
      if (!handedOff) await staging.delete(recursive: true);
    }
  }

  /// Linux ships one AppImage file: the new one is staged beside it, then the same
  /// helper swaps the files and starts it, restoring the old one if that fails.
  Future<void> installAppImage(File download) async {
    final current = appImagePath;
    if (current.isEmpty) {
      throw const UpdateException(
        'This Yomi was not started from its AppImage. Download the new AppImage instead.',
      );
    }
    final target = File(current);
    final Directory staging;
    try {
      staging = await target.parent.createTemp('.yomi-update-');
    } on FileSystemException {
      throw const UpdateException(
        'Yomi needs a writable folder for its AppImage. Move it to your home folder and retry.',
      );
    }
    var handedOff = false;
    try {
      final staged = await download.copy('${staging.path}/Yomi.AppImage');
      if (!await _isLinuxProgram(staged)) {
        throw const UpdateException('The update was not a Yomi AppImage.');
      }
      await _run('chmod', ['+x', staged.path]);
      await beforeRestart?.call();
      final helper = File('${staging.path}/install.sh');
      await helper.writeAsString(desktopInstallScript);
      await Process.start('/bin/sh', [
        helper.path,
        '$pid',
        target.path,
        staged.path,
        staging.path,
        'appimage',
        '${download.parent.path}/install.log',
      ], mode: ProcessStartMode.detached);
      handedOff = true;
      exit(0);
    } finally {
      if (!handedOff) await staging.delete(recursive: true);
    }
  }

  /// AppImages are ELF programs; anything else is a broken or wrong download.
  Future<bool> _isLinuxProgram(File file) async {
    final header = await file.openRead(0, 4).expand((bytes) => bytes).toList();
    return header.length == 4 &&
        header[0] == 0x7F &&
        header[1] == 0x45 &&
        header[2] == 0x4C &&
        header[3] == 0x46;
  }

  Future<void> _run(String command, List<String> arguments) async {
    final result = await Process.run(command, arguments);
    if (result.exitCode != 0) {
      throw const UpdateException(
        "Yomi couldn't prepare the update. Your current app is unchanged.",
      );
    }
  }
}

/// All moves stay on one filesystem. If activation or launch fails, restore the
/// original bundle. Keep a log outside staging so failures can be diagnosed.
const desktopInstallScript = r'''
set -eu
old_pid=$1
target=$2
staged=$3
work=$4
platform=$5
exec >> "$6" 2>&1
backup="$work/previous"
launch() {
  if [ "$platform" = macos ]; then
    /usr/bin/open -n "$target"
  elif [ "$platform" = appimage ]; then
    "$target" </dev/null &
    child=$!
    sleep 2
    kill -0 "$child" 2>/dev/null
  else
    "$target/yomi" </dev/null &
    child=$!
    sleep 2
    kill -0 "$child" 2>/dev/null
  fi
}
# Bound the wait in case shutdown did not complete. Never change a running app.
attempt=0
while kill -0 "$old_pid" 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo 'Yomi did not exit; leaving the current app unchanged.'
    exit 1
  fi
  sleep 1
done
if ! mv "$target" "$backup"; then
  echo 'Could not back up Yomi.'
  exit 1
fi
if ! mv "$staged" "$target"; then
  mv "$backup" "$target"
  launch || true
  exit 1
fi
if ! launch; then
  mv "$target" "$staged"
  mv "$backup" "$target"
  launch || true
  echo 'Launch failed; restored the previous version.'
  exit 1
fi
rm -rf "$work"
''';
