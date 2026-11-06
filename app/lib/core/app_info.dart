/// This copy of the app: its version and the platform it runs on.
class AppInfo {
  const AppInfo({this.version = '', this.buildNumber = '', this.platform = ''});

  final String version;
  final String buildNumber;
  final String platform;

  bool get isKnown => version.isNotEmpty;

  /// Shown at the bottom of Settings, so people can say which version they have.
  String get label =>
      buildNumber.isEmpty ? 'Yomi $version' : 'Yomi $version ($buildNumber)';

  /// Sent with every server request. The server's player list then shows which
  /// version each person's device runs.
  String get clientName => isKnown ? 'Yomi $version $platform' : 'Yomi';
}

/// Set once at startup, before any server request. Unknown until then.
AppInfo appInfo = const AppInfo();
