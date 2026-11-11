import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/state/session.dart';

const dead = 'http://192.168.1.18:4533';
const away = 'http://100.88.180.104:4533';
const backup = 'http://backup.example:4533';

void main() {
  late SessionController session;

  Future<void> start(Set<String> working, {bool embedded = false}) async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'http://127.0.0.1:1', // main address is dead
      'home_url': dead,
      'username': 'u',
      'password': 'p',
      'route_mode': 'away',
      'extra_urls': '["$backup","$away"]',
    });
    session = SessionController(
      tunnelResolve: embedded
          ? (url) async => url == backup ? "http://127.0.0.1:40002" : null
          : null,
      uploadPortFor: (url) => url == "http://127.0.0.1:40002" ? 40003 : 4534,
      probe: (url, user, password) async => false,
      urlProbe: (url, user, password) async => ProbeResult(
        url: url,
        isOk: working.contains(url),
        elapsed: Duration.zero,
        problem: 'No answer',
      ),
    );
    await session.restore();
    await session.checkServer();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('a suspended backup tunnel restarts and resolves fresh ports', () async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'http://127.0.0.1:1',
      'username': 'u',
      'password': 'p',
      'route_mode': 'away',
      'extra_urls': '["$backup"]',
    });
    var restarted = false;
    session = SessionController(
      probe: (_, _, _) async => false,
      urlProbe: (url, _, _) async =>
          ProbeResult(url: url, isOk: false, elapsed: Duration.zero),
      tunnelProbe: (url, _, _) async => ProbeResult(
        url: url,
        isOk: url.endsWith(':41002'),
        elapsed: Duration.zero,
      ),
      tunnelResolve: (url) async => url == backup
          ? 'http://127.0.0.1:${restarted ? 41002 : 40002}'
          : null,
      tunnelReconnect: () async {
        restarted = true;
        return 'http://127.0.0.1:41000';
      },
    );
    await session.restore();
    await session.checkServer();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(restarted, isTrue);
    expect(session.serverUrl, 'http://127.0.0.1:41002');
    expect(session.isServerReachable, isTrue);
    expect(session.isOnTunnel, isTrue);
    session.dispose();
  });

  test(
    'doctor and playback use backup tunnel with its companion port',
    () async {
      await start({'http://127.0.0.1:40002'}, embedded: true);
      expect(session.isServerReachable, isTrue);
      expect(session.serverUrl, 'http://127.0.0.1:40002');
      expect(session.isOnBackup, isTrue);
      expect(session.uploadServicePort, 40003);
      final results = await session.diagnose();
      expect(results.singleWhere((r) => r.url == backup).isOk, isTrue);
      session.useUrl(backup);
      expect(session.serverUrl, 'http://127.0.0.1:40002');
      session.dispose();
    },
  );

  test(
    'switches to the first working backup when the main address is dead',
    () async {
      await start({away, backup});

      expect(session.isServerReachable, isTrue);
      expect(session.isOnBackup, isTrue);
      expect(
        session.serverUrl,
        backup,
      ); // priority order: extras after home/away
      expect(session.routeLabel, 'Backup address');
    },
  );

  test('a live backup is used without waiting for a main address that hangs', () async {
    // Arrange: the home address never answers at all; the backup answers at once.
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'http://127.0.0.1:1',
      'home_url': dead,
      'username': 'u',
      'password': 'p',
      'route_mode': 'away',
      'extra_urls': '["$backup"]',
    });
    final never = Completer<ProbeResult>();
    session = SessionController(
      probe: (url, user, password) async => false,
      urlProbe: (url, user, password) => url == dead
          ? never.future
          : Future.value(
              ProbeResult(
                url: url,
                isOk: url == backup,
                elapsed: Duration.zero,
                problem: 'No answer',
              ),
            ),
    );
    await session.restore();

    // Act
    // Restoring already started a check, so wait for whichever one is running.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (session.serverUrl != backup && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    // Assert
    expect(session.isServerReachable, isTrue);
    expect(session.serverUrl, backup);
    session.dispose();
  });

  test('a backup added while offline is used straight away', () async {
    // Arrange
    final working = <String>{};
    await start(working);
    expect(session.isServerReachable, isFalse);

    // Act
    working.add('http://10.0.0.5:4533');
    await session.addExtraUrl('10.0.0.5');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Assert
    expect(session.isServerReachable, isTrue);
    expect(session.serverUrl, 'http://10.0.0.5:4533');
    session.dispose();
  });

  test('stays offline when no address answers', () async {
    await start({});

    expect(session.isServerReachable, isFalse);
  });

  test(
    'diagnose reports every address and extras can be added and removed',
    () async {
      await start({away});
      await session.addExtraUrl('10.0.0.5');
      expect(session.extraUrls, contains('http://10.0.0.5:4533'));

      final results = await session.diagnose();
      expect(results.length, session.candidateUrls.length);
      expect(results.where((r) => r.isOk).single.url, away);

      await session.removeExtraUrl('http://10.0.0.5:4533');
      expect(session.extraUrls, isNot(contains('http://10.0.0.5:4533')));
    },
  );
}
