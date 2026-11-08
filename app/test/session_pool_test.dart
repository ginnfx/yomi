import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/state/session.dart';

http.Response _pong() => http.Response(
  '{"subsonic-response":{"status":"ok","version":"1.16.1"}}',
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  const away = 'http://away.test';
  const fast = 'http://fast.test:4533';
  const dead = 'http://dead.test:4533';

  test(
    'refreshPool tells the pool which servers answer and how fast',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({
        'server_url': away,
        'username': 'u',
        'password': 'p',
      });
      final probed = <String>[];
      final session = SessionController(
        httpClient: MockClient((_) async => _pong()),
        urlProbe: (url, _, _) async {
          probed.add(url);
          return ProbeResult(
            url: url,
            isOk: url != dead,
            elapsed: Duration(milliseconds: url == fast ? 5 : 300),
          );
        },
        roleProbe: (_, _) async => false,
      );
      await session.restoreSaved();
      await session.addExtraUrl(fast);
      await session.addExtraUrl(dead);
      await _until(() => probed.contains(dead));
      await session.refreshPool(force: true);

      expect(session.pool.servers, containsAll([away, fast, dead]));
      expect(session.pool.rank().first, fast);
      expect(session.pool.rank(), isNot(contains(dead)));
      session.dispose();
    },
  );

  test(
    'a single known server is never probed by the periodic refresh',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({
        'server_url': away,
        'username': 'u',
        'password': 'p',
      });
      var probes = 0;
      final session = SessionController(
        httpClient: MockClient((_) async => _pong()),
        urlProbe: (url, _, _) async {
          probes++;
          return ProbeResult(url: url, isOk: true, elapsed: Duration.zero);
        },
        roleProbe: (_, _) async => false,
      );
      await session.restoreSaved();
      expect(probes, 0);
      session.dispose();
    },
  );

  test('suggestedUrls mixes known addresses with the extra hosts', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({
      'server_url': away,
      'username': 'u',
      'password': 'p',
    });
    final session = SessionController(
      httpClient: MockClient((_) async => _pong()),
      urlProbe: (url, _, _) async =>
          ProbeResult(url: url, isOk: true, elapsed: Duration.zero),
      roleProbe: (_, _) async => false,
    );
    await session.restoreSaved();

    expect(session.suggestedUrls(extraHosts: ['mac.test']), [
      'http://mac.test:4533',
    ]);
    final results = await session.diagnoseUrls(['http://mac.test:4533']);
    expect(results.single.isOk, isTrue);
    session.dispose();
  });
}
