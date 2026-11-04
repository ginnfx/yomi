import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/ui/widgets/async_section.dart';

http.Response _pong() => http.Response(
  '{"subsonic-response":{"status":"ok"}}',
  200,
);

void main() {
  group('AsyncSection', () {
    Widget section({
      required Future<String> Function() load,
      String? initial,
      Object? reloadKey,
    }) => MaterialApp(
      home: Material(
        child: AsyncSection<String>(
          load: load,
          initialData: initial,
          reloadKey: reloadKey,
          skeleton: const Text('skeleton'),
          builder: (_, value) => Text(value),
        ),
      ),
    );

    testWidgets('saved data appears on the very first frame', (tester) async {
      final pending = Completer<String>();
      await tester.pumpWidget(
        section(load: () => pending.future, initial: 'Saved'),
      );

      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('skeleton'), findsNothing);
      pending.complete('Fresh');
      await tester.pumpAndSettle();
      expect(find.text('Fresh'), findsOneWidget);
    });

    testWidgets('a failed refresh keeps what is showing', (tester) async {
      await tester.pumpWidget(
        section(load: () => Future.error('down'), initial: 'Saved'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('a new route reloads in place with no skeleton', (tester) async {
      var value = 'One';
      Future<String> load() async => value;
      await tester.pumpWidget(section(load: load, reloadKey: 'home'));
      await tester.pumpAndSettle();

      value = 'Two';
      await tester.pumpWidget(section(load: load, reloadKey: 'away'));
      expect(find.text('skeleton'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Two'), findsOneWidget);
    });
  });

  group('startup', () {
    test('signs back in from saved data without touching the network', () async {
      FlutterSecureStorage.setMockInitialValues({
        'server_url': 'http://away.test',
        'home_url': 'http://home.test',
        'last_url': 'http://home.test',
        'username': 'u',
        'password': 'p',
      });
      var probes = 0;
      final session = SessionController(
        probe: (_, _, _) async {
          probes++;
          return true;
        },
        urlProbe: (url, _, _) async {
          probes++;
          return ProbeResult(url: url, isOk: true, elapsed: Duration.zero);
        },
        roleProbe: (_, _) async => false,
      );

      expect(session.isRestoring, isTrue);
      await session.restoreSaved();

      expect(session.isRestoring, isFalse);
      expect(session.isSignedIn, isTrue);
      expect(session.serverUrl, 'http://home.test');
      expect(session.route, ActiveRoute.home);
      expect(probes, 0);
      session.dispose();
    });

    test('an account keeps its ID across restarts and loses it on sign-out', () async {
      FlutterSecureStorage.setMockInitialValues({
        'server_url': 'http://away.test',
        'username': 'u',
        'password': 'p',
      });
      Future<String?> restore() async {
        final session = SessionController(roleProbe: (_, _) async => false);
        await session.restoreSaved();
        final id = session.accountId;
        session.dispose();
        return id;
      }

      final first = await restore();
      expect(first, isNotNull);
      expect(await restore(), first);
    });
  });

  group('routine checks', () {
    Future<void> waitUntil(bool Function() condition) async {
      for (var i = 0; i < 200 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(condition(), isTrue);
    }

    test('one failed check on resume changes nothing', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({
        'server_url': 'http://away.test',
        'username': 'u',
        'password': 'p',
      });
      var pings = 0;
      var failovers = 0;
      final session = SessionController(
        httpClient: MockClient((_) async {
          pings++;
          if (pings == 1) throw http.ClientException('slow wake');
          return _pong();
        }),
        urlProbe: (url, _, _) async {
          failovers++;
          return ProbeResult(url: url, isOk: false, elapsed: Duration.zero);
        },
        roleProbe: (_, _) async => false,
      );
      await session.restoreSaved();
      final client = session.client;

      session.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitUntil(() => pings >= 2);
      await Future<void>.delayed(Duration.zero);

      expect(session.isServerReachable, isTrue);
      expect(failovers, 0);
      expect(identical(session.client, client), isTrue);
      session.dispose();
    });

    test('repeated failures still reach the offline state', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({
        'server_url': 'http://away.test',
        'username': 'u',
        'password': 'p',
      });
      final session = SessionController(
        httpClient: MockClient((_) async {
          throw http.ClientException('down');
        }),
        urlProbe: (url, _, _) async =>
            ProbeResult(url: url, isOk: false, elapsed: Duration.zero),
        roleProbe: (_, _) async => false,
      );
      await session.restoreSaved();

      session.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitUntil(() => !session.isServerReachable);

      session.dispose();
    });
  });
}
