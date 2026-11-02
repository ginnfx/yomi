import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/state/session.dart';

const dead = 'http://192.168.1.18:4533';
const away = 'http://100.88.180.104:4533';
const backup = 'http://backup.example:4533';

void main() {
  late SessionController session;

  Future<void> start(Set<String> working) async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'http://127.0.0.1:1', // main address is dead
      'home_url': dead,
      'username': 'u',
      'password': 'p',
      'route_mode': 'away',
      'extra_urls': '["$backup","$away"]',
    });
    session = SessionController(
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
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

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
