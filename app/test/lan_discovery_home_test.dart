import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/core/lan_discovery.dart';

void main() {
  Future<ProbeResult> okProbe(String url, String user, String password) async =>
      ProbeResult(url: url, isOk: true, elapsed: Duration.zero);

  test(
    'never scans, so never sends the login, without a known home address',
    () async {
      var probes = 0;
      final found = await findServerOnLan(
        'me',
        'secret',
        probe: (url, user, password) {
          probes++;
          return okProbe(url, user, password);
        },
        addresses: () async => ['192.168.1.20'],
        answers: (_) async => true,
      );
      expect(found, isNull);
      expect(probes, 0);
    },
  );

  test('does not scan a different network from the saved home one', () async {
    var probes = 0;
    final found = await findServerOnLan(
      'me',
      'secret',
      home: 'http://192.168.1.5:4533',
      probe: (url, user, password) {
        probes++;
        return okProbe(url, user, password);
      },
      addresses: () async => ['10.0.0.20'],
      answers: (_) async => true,
    );
    expect(found, isNull);
    expect(probes, 0);
  });

  test('finds the server again on the home network', () async {
    final found = await findServerOnLan(
      'me',
      'secret',
      home: 'http://192.168.1.5:4533',
      probe: okProbe,
      addresses: () async => ['192.168.1.20'],
      answers: (host) async => host == '192.168.1.9',
    );
    expect(found, 'http://192.168.1.9:4533');
  });

  test('warns about plain http only outside home and Tailscale', () {
    expect(isUnencryptedPublicUrl('http://music.example.com:4533'), isTrue);
    expect(isUnencryptedPublicUrl('https://music.example.com'), isFalse);
    expect(isUnencryptedPublicUrl('http://192.168.1.5:4533'), isFalse);
    expect(isUnencryptedPublicUrl('http://100.88.1.2:4533'), isFalse);
  });
}
