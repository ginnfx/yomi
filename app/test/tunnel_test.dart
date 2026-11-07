import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/core/tunnel/tunnel_bridge.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/state/tunnel_controller.dart';

class FakeBridge implements TunnelBridge {
  final List<String> calls = [];
  String currentState = 'Running';
  bool failStart = false;
  bool failState = false;
  String? lastKey;
  int nextPort = 40000;

  @override
  Future<void> start({
    required String stateDir,
    required String authKey,
    required String hostname,
  }) async {
    calls.add('start');
    lastKey = authKey;
    if (failStart) throw PlatformException(code: 'tunnel', message: 'expired');
  }

  @override
  Future<int> forward(String remote) async {
    calls.add('forward $remote');
    return nextPort++;
  }

  @override
  Future<String> state() async {
    if (failState)
      throw PlatformException(code: 'tunnel', message: 'state failed');
    return currentState;
  }

  @override
  Future<void> networkChanged() async => calls.add('networkChanged');

  @override
  Future<void> stop() async => calls.add('stop');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FakeBridge bridge;
  late TunnelController tunnel;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('tunnel');
    SharedPreferences.setMockInitialValues({});
    bridge = FakeBridge();
    tunnel = TunnelController(
      bridge: bridge,
      prefs: await SharedPreferences.getInstance(),
      stateDir: Directory('${dir.path}/ts'),
    );
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('TunnelController', () {
    test('rejects something that is not an invite code, offline', () async {
      await expectLater(
        tunnel.join('hello', '100.1.2.3'),
        throwsA(isA<TunnelException>()),
      );
      expect(bridge.calls, isEmpty);
      expect(tunnel.isEnrolled, isFalse);
    });

    test('a refused code leaves the device not joined', () async {
      bridge.failStart = true;
      await expectLater(
        tunnel.join('tskey-auth-abc', '100.1.2.3'),
        throwsA(isA<TunnelException>()),
      );
      expect(tunnel.isEnrolled, isFalse);
    });

    test('joining forwards only the music and upload ports', () async {
      await tunnel.join(' tskey-auth-abc ', '100.1.2.3');
      expect(tunnel.isEnrolled, isTrue);
      expect(bridge.lastKey, 'tskey-auth-abc');
      expect(bridge.calls.where((call) => call.startsWith('forward')), [
        'forward 100.1.2.3:4533',
        'forward 100.1.2.3:4534',
      ]);
      expect(tunnel.musicUrl, 'http://127.0.0.1:40000');
      expect(tunnel.uploadPortFor('http://127.0.0.1:40000'), 40001);
      expect(tunnel.uploadPortFor('http://192.168.1.4:4533'), 4534);
    });

    test('the invite code is never kept', () async {
      await tunnel.join('tskey-auth-secret', '100.1.2.3');
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect('${prefs.get(key)}', isNot(contains('tskey')));
      }
      bridge.currentState = 'Stopped';
      await tunnel.connect();
      expect(bridge.lastKey, '');
    });

    test('a device that has not joined never starts the tunnel', () async {
      expect(await tunnel.connect(), isNull);
      expect(bridge.calls, isEmpty);
    });

    test('a healthy tunnel is reused, a stopped one restarted', () async {
      await tunnel.join('tskey-auth-abc', '100.1.2.3');
      final first = await tunnel.connect();
      expect(first, 'http://127.0.0.1:40000');
      expect(bridge.calls.where((c) => c == 'start'), hasLength(1));

      bridge.currentState = 'Stopped';
      final second = await tunnel.connect();
      expect(second, 'http://127.0.0.1:40002');
      expect(bridge.calls, contains('stop'));
    });

    test('failing to restart reports no tunnel rather than throwing', () async {
      await tunnel.join('tskey-auth-abc', '100.1.2.3');
      bridge
        ..currentState = 'Stopped'
        ..failStart = true;
      expect(await tunnel.connect(), isNull);
    });

    test('recovery restarts a backend that still reports Running', () async {
      await tunnel.join('tskey-auth-abc', '100.1.2.3');
      expect(await tunnel.reconnect(), 'http://127.0.0.1:40002');
      expect(bridge.calls.where((c) => c == 'start'), hasLength(2));
      expect(bridge.lastKey, '');
    });

    test('native state errors allow a later recovery', () async {
      await tunnel.join('tskey-auth-abc', '100.1.2.3');
      bridge.failState = true;
      expect(await tunnel.connect(), isNull);
      bridge.failState = false;
      expect(await tunnel.connect(), isNotNull);
    });

    test(
      'network changes notify the monitor without starting a node',
      () async {
        await tunnel.networkChanged();
        expect(bridge.calls, ['networkChanged']);
      },
    );

    test('leaving removes the node key', () async {
      await tunnel.join('tskey-auth-abc', '100.1.2.3');
      File('${dir.path}/ts/node-key').writeAsStringSync('secret');
      await tunnel.leave();
      expect(tunnel.isEnrolled, isFalse);
      expect(Directory('${dir.path}/ts').existsSync(), isFalse);
    });
  });

  group('SessionController with a tunnel', () {
    const home = 'http://192.168.1.4:4533';
    const away = 'http://127.0.0.1:1';
    const tunnelUrl = 'http://127.0.0.1:40000';
    late int tunnelStarts;

    Future<SessionController> start(
      Set<String> working, {
      bool hasInvite = true,
    }) async {
      tunnelStarts = 0;
      FlutterSecureStorage.setMockInitialValues({
        'server_url': away,
        'home_url': home,
        'username': 'u',
        'password': 'p',
        'route_mode': 'away',
      });
      final session = SessionController(
        probe: (url, user, password) async => working.contains(url),
        urlProbe: (url, user, password) async => ProbeResult(
          url: url,
          isOk: working.contains(url),
          elapsed: Duration.zero,
        ),
        tunnelConnect: () async {
          tunnelStarts++;
          return hasInvite ? tunnelUrl : null;
        },
        uploadPortFor: (url) => url == tunnelUrl ? 40001 : 4534,
      );
      await session.restore();
      await session.checkServer();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return session;
    }

    test('a failed tunnel probe retries with a restarted tunnel', () async {
      FlutterSecureStorage.setMockInitialValues({
        'server_url': away,
        'username': 'u',
        'password': 'p',
      });
      var restarts = 0;
      final session = SessionController(
        tunnelConnect: () async => tunnelUrl,
        tunnelReconnect: () async {
          restarts++;
          return 'http://127.0.0.1:40002';
        },
        urlProbe: (url, user, password) async => ProbeResult(
          url: url,
          isOk: url.endsWith(':40002'),
          elapsed: Duration.zero,
        ),
      );
      await session.restoreSaved();
      await session.checkServer();
      expect(restarts, 1);
      expect(session.isChecking, isFalse);
      expect(session.isServerReachable, isTrue);
      expect(session.serverUrl, 'http://127.0.0.1:40002');
      session.dispose();
    });

    test('a tunnel that stopped answering is restarted at once', () async {
      FlutterSecureStorage.setMockInitialValues({
        'server_url': away,
        'username': 'u',
        'password': 'p',
      });
      const restarted = 'http://127.0.0.1:40003';
      var working = {tunnelUrl};
      var connects = 0;
      var restarts = 0;
      final session = SessionController(
        tunnelConnect: () async {
          connects++;
          return tunnelUrl;
        },
        tunnelReconnect: () async {
          restarts++;
          return restarted;
        },
        urlProbe: (url, user, password) async => ProbeResult(
          url: url,
          isOk: working.contains(url),
          elapsed: Duration.zero,
        ),
      );
      await session.restoreSaved();
      await session.checkServer();
      expect(session.isOnTunnel, isTrue);
      expect(connects, 1);

      // The phone suspended the node: the old address is dead, a restart works.
      working = {restarted};
      await session.checkServer();

      expect(restarts, 1, reason: 'restarted, not just asked if it is running');
      expect(
        connects,
        1,
        reason: 'no second trip through the "is it running" path',
      );
      expect(session.serverUrl, restarted);
      expect(session.isServerReachable, isTrue);
      session.dispose();
    });

    test('a recovery error releases the checking guard', () async {
      FlutterSecureStorage.setMockInitialValues({
        'server_url': away,
        'username': 'u',
        'password': 'p',
      });
      final session = SessionController(
        tunnelConnect: () async => throw PlatformException(code: 'tunnel'),
      );
      await session.restoreSaved();
      await session.checkServer();
      expect(session.isChecking, isFalse);
      expect(session.isServerReachable, isFalse);
      session.dispose();
    });

    test('an address that works means the tunnel never starts', () async {
      final session = await start({home});
      expect(session.isOnTunnel, isFalse);
      expect(session.serverUrl, home);
      expect(tunnelStarts, 0);
    });

    test('when everything direct fails, it goes through the tunnel', () async {
      final session = await start({tunnelUrl});
      expect(session.isOnTunnel, isTrue);
      expect(session.serverUrl, tunnelUrl);
      expect(session.uploadServicePort, 40001);
      expect(session.routeLabel, 'Invite tunnel');
      expect(session.isServerReachable, isTrue);
    });

    test('a route refresh does not abandon a working tunnel', () async {
      final session = await start({tunnelUrl});
      await session.refreshRoute();
      expect(session.serverUrl, tunnelUrl);
      expect(session.isOnTunnel, isTrue);
    });

    test('without an invite, a dead server stays offline', () async {
      final session = await start(const {}, hasInvite: false);
      expect(session.isOnTunnel, isFalse);
      expect(session.isServerReachable, isFalse);
    });

    test('a tunnel that cannot reach the server stays offline', () async {
      final session = await start(const {});
      expect(session.isOnTunnel, isFalse);
      expect(session.isServerReachable, isFalse);
    });
  });
}
