import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/session.dart';

const home = 'http://192.168.1.18:4533';
const away = 'http://100.88.180.104:4533';

void main() {
  late StreamController<List<ConnectivityResult>> network;
  late ConnectivityController connectivity;
  var homeReachable = true;
  var probes = 0;

  Future<SessionController> signedIn({
    List<ConnectivityResult> on = const [ConnectivityResult.wifi],
    bool withHome = true,
  }) async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': away,
      if (withHome) 'home_url': home,
      'username': 'keli',
      'password': 'pw',
    });
    network = StreamController<List<ConnectivityResult>>.broadcast();
    connectivity = ConnectivityController(
      changes: network.stream,
      check: () async => on,
    );
    await Future<void>.delayed(Duration.zero);
    final session = SessionController(
      connectivity: connectivity,
      probe: (url, user, password) async {
        probes++;
        return homeReachable;
      },
    );
    await session.restore();
    return session;
  }

  setUp(() {
    homeReachable = true;
    probes = 0;
  });

  test(
    'uses the home address on home Wi-Fi when the home server answers',
    () async {
      final session = await signedIn();

      expect(session.route, ActiveRoute.home);
      expect(session.serverUrl, home);
      expect(session.routeLabel, 'Home network');
    },
  );

  test(
    'falls back to the away address when the home server does not answer',
    () async {
      homeReachable = false;
      final session = await signedIn();

      expect(session.route, ActiveRoute.away);
      expect(session.serverUrl, away);
    },
  );

  test(
    'on mobile data it never wastes time probing the home address',
    () async {
      final session = await signedIn(on: [ConnectivityResult.mobile]);

      expect(session.serverUrl, away);
      expect(probes, 0);
    },
  );

  test('switches by itself when the network changes', () async {
    final session = await signedIn();
    expect(session.serverUrl, home);

    // Waits for the switch instead of a fixed time, which a busy machine can overrun.
    Future<void> waitForUrl(String url) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (session.serverUrl != url && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    network.add([ConnectivityResult.mobile]);
    await waitForUrl(away);
    expect(session.serverUrl, away);
    expect(session.routeLabel, 'Away from home');

    network.add([ConnectivityResult.wifi]);
    await waitForUrl(home);
    expect(session.serverUrl, home);
  });

  test('without a home address it always uses the one address', () async {
    final session = await signedIn(withHome: false);

    expect(session.serverUrl, away);
    expect(session.hasHomeAddress, isFalse);
    expect(probes, 0);
  });

  test('manual modes override the automatic choice', () async {
    final session = await signedIn();

    await session.updateConnection(mode: RouteMode.away);
    expect(session.serverUrl, away);

    await session.updateConnection(mode: RouteMode.home);
    expect(session.serverUrl, home);
  });

  test(
    'addresses are normalised and a blank home address turns switching off',
    () async {
      final session = await signedIn();

      await session.updateConnection(home: '192.168.1.40');
      expect(session.homeUrl, 'http://192.168.1.40:4533');

      await session.updateConnection(home: '');
      expect(session.hasHomeAddress, isFalse);
      expect(session.serverUrl, away);
    },
  );
}
