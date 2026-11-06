/// This copy of the app: its version and the platform it runs on.
class AppInfo {
  const AppInfo({this.version = '', this.platform = ''});

  final String version;
  final String platform;

  bool get isKnown => version.isNotEmpty;

  /// Shown at the bottom of Settings, so people can say which version they have.
  String get label => 'Yomi $version';

  /// Sent with every server request. The server's player list then shows which
  /// version each person's device runs.
  String get clientName => isKnown ? 'Yomi $version $platform' : 'Yomi';
}

/// Set once at startup, before any server request. Unknown until then.
AppInfo appInfo = const AppInfo();
