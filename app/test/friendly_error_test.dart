import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/friendly_error.dart';
import 'package:yomi/core/subsonic_client.dart';

FriendlyError explain(
  Object error, {
  bool offline = false,
  bool home = false,
  bool hasHome = false,
  bool wifi = true,
}) => explainError(
  error,
  isOffline: offline,
  isAtHomeRoute: home,
  hasHomeAddress: hasHome,
  isOnWifi: wifi,
);

void main() {
  const unreachable = SubsonicException('x', kind: ErrorKind.unreachable);

  test('offline always says so and points to downloads', () {
    final e = explain(unreachable, offline: true);
    expect(e.title, "You're offline");
    expect(e.hint, contains('downloaded'));
    expect(e.action, ErrorAction.none);
  });

  test(
    'away from home on mobile data tells the user to switch Tailscale on',
    () {
      final e = explain(unreachable, wifi: false);
      expect(e.hint, contains('Tailscale'));
    },
  );

  test('failing on the home route blames the server phone, not the user', () {
    final e = explain(unreachable, home: true, hasHome: true);
    expect(e.title, contains('home server'));
    expect(e.hint, contains('Wi-Fi'));
  });

  test('on non-home Wi-Fi with a home address saved it suggests Tailscale or settings', () {
    final e = explain(unreachable, hasHome: true);
    expect(e.hint, contains('Tailscale'));
    expect(e.action, ErrorAction.openSettings);
  });

  test('wrong password and wrong address get their own explanations', () {
    expect(
      explain(const SubsonicException('x', kind: ErrorKind.badCredentials))
          .title,
      contains('password'),
    );
    expect(
      explain(const SubsonicException('x', kind: ErrorKind.notNavidrome)).title,
      contains("isn't your music server"),
    );
    expect(
      explain(const SubsonicException('x', kind: ErrorKind.server)).title,
      contains('problem'),
    );
  });

  test('plain network exceptions are treated as unreachable', () {
    expect(
      explain(const SocketException('no route')).title,
      contains("Can't reach"),
    );
  });

  test('anything else shows the original message instead of hiding it', () {
    final e = explain(StateError('odd'));
    expect(e.title, 'Something went wrong');
    expect(e.hint, contains('odd'));
  });
}
