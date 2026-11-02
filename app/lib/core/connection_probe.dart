import 'dart:async';

import 'subsonic_client.dart';

const Duration kProbeTimeout = Duration(seconds: 3);

/// What happened when Yomi tried one server address.
class ProbeResult {
  const ProbeResult({
    required this.url,
    required this.isOk,
    required this.elapsed,
    this.problem = '',
  });

  final String url;
  final bool isOk;
  final Duration elapsed;

  /// Plain-words reason when [isOk] is false.
  final String problem;
}

typedef UrlProbe = Future<ProbeResult> Function(
  String url,
  String user,
  String password,
);

/// Tries one address and explains the outcome in a few words.
Future<ProbeResult> probeUrl(
  String url,
  String user,
  String password, {
  Duration timeout = kProbeTimeout,
}) async {
  final watch = Stopwatch()..start();
  try {
    await SubsonicClient(
      baseUrl: url,
      username: user,
      password: password,
    ).ping(timeout: timeout);
    return ProbeResult(url: url, isOk: true, elapsed: watch.elapsed);
  } on SubsonicException catch (error) {
    return ProbeResult(
      url: url,
      isOk: false,
      elapsed: watch.elapsed,
      problem: _describe(error),
    );
  } on Exception {
    return ProbeResult(
      url: url,
      isOk: false,
      elapsed: watch.elapsed,
      problem: 'No answer',
    );
  }
}

String _describe(SubsonicException error) => switch (error.kind) {
  ErrorKind.badCredentials => 'Wrong username or password',
  ErrorKind.notNavidrome => 'Answered, but not Navidrome',
  ErrorKind.server => 'Server error',
  ErrorKind.unreachable => 'No answer',
  ErrorKind.other => error.message,
};
