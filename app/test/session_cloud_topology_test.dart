import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/core/server_topology.dart';
import 'package:yomi/core/vault_storage.dart';
import 'package:yomi/state/session.dart';

void main() {
  VaultStorage storage() => VaultStorage(
    const FlutterSecureStorage(),
    legacyKeys: const [],
    isVaultOn: false,
  );

  test('upgrades saved personal routes once and keeps account data', () async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'http://100.88.180.104:4533',
      'home_url': 'http://192.168.1.18:4533',
      'extra_urls': jsonEncode([cloudMusicUrl, macMusicUrl]),
      'last_url': macMusicUrl,
      'username': 'personal-user',
      'password': 'saved-password',
      'account_id': 'existing-offline-library',
    });
    final vault = storage();
    final session = SessionController(
      storage: vault,
      migratePersonalServers: true,
      roleProbe: (_, _) async => false,
    );
    await session.restoreSaved();
    expect(session.serverUrl, cloudMusicUrl);
    expect(session.awayUrl, cloudMusicUrl);
    expect(session.homeUrl, isEmpty);
    expect(session.extraUrls, [macMusicUrl]);
    expect(await vault.read(key: 'username'), 'personal-user');
    expect(await vault.read(key: 'password'), 'saved-password');
    expect(await vault.read(key: 'account_id'), 'existing-offline-library');
    expect(await vault.read(key: 'server_topology'), cloudTopologyVersion);
    session.dispose();

    // A later deliberate user choice is not overwritten on every app launch.
    await vault.write(key: 'server_url', value: macMusicUrl);
    final next = SessionController(
      storage: vault,
      migratePersonalServers: true,
      roleProbe: (_, _) async => false,
    );
    await next.restoreSaved();
    expect(next.awayUrl, macMusicUrl);
    next.dispose();
  });

  test('uses Mac when cloud fails and returns after cloud recovery', () async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': cloudMusicUrl,
      'extra_urls': jsonEncode([macMusicUrl]),
      'username': 'u',
      'password': 'p',
      'route_mode': 'away',
    });
    var cloudWorks = false;
    final session = SessionController(
      storage: storage(),
      roleProbe: (url, _) async => url == macMusicUrl,
      urlProbe: (url, _, _) async => ProbeResult(
        url: url,
        isOk: url == macMusicUrl || cloudWorks,
        elapsed: Duration.zero,
      ),
      httpClient: MockClient(
        (request) async => http.Response(
          '{"subsonic-response":{"status":"ok","version":"1.16.1"}}',
          request.url.host == '100.82.99.19' && !cloudWorks ? 503 : 200,
        ),
      ),
    );
    await session.restoreSaved();
    await session.checkServer();
    await Future<void>.delayed(Duration.zero);
    expect(session.serverUrl, macMusicUrl);
    expect(session.isOnReplica, isTrue);
    expect(session.isServerReachable, isTrue);

    await session.returnToPrimary();
    expect(session.serverUrl, macMusicUrl);
    cloudWorks = true;
    await session.returnToPrimary();
    expect(session.serverUrl, cloudMusicUrl);
    expect(session.isOnReplica, isFalse);
    session.dispose();
  });
  test('cloud uses embedded tunnel when the system VPN is off', () async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': cloudMusicUrl,
      'extra_urls': jsonEncode([macMusicUrl]),
      'username': 'u',
      'password': 'p',
      'route_mode': 'away',
    });
    final session = SessionController(
      storage: storage(),
      roleProbe: (_, _) async => false,
      urlProbe: (url, _, _) async =>
          ProbeResult(url: url, isOk: false, elapsed: Duration.zero),
      tunnelResolve: (url) async =>
          url == cloudMusicUrl ? 'http://127.0.0.1:44000' : null,
      tunnelProbe: (url, _, _) async => ProbeResult(
        url: url,
        isOk: url == 'http://127.0.0.1:44000',
        elapsed: Duration.zero,
      ),
      uploadPortFor: (url) => url == 'http://127.0.0.1:44000' ? 44001 : 4534,
      httpClient: MockClient((_) async => http.Response('unreachable', 503)),
    );
    await session.restoreSaved();
    await session.checkServer();
    expect(session.serverUrl, 'http://127.0.0.1:44000');
    expect(session.isOnTunnel, isTrue);
    expect(session.isOnBackup, isFalse);
    expect(session.uploadServicePort, 44001);
    session.dispose();
  });
}
