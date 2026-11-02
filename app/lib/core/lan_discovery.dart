import 'dart:async';
import 'dart:io';

import 'connection_probe.dart';

const int _navidromePort = 4533;
const Duration _scanTimeout = Duration(milliseconds: 700);
const int _scanBatchSize = 64;

/// Finds the server on the current Wi-Fi and returns its address, or null.
typedef LanFinder = Future<String?> Function(String user, String password);

/// True for the ranges routers hand out. Tailscale's 100.x is deliberately not included.
bool isPrivateLanAddress(String ip) {
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return false;
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
}

/// "192.168.1.10" -> every other host in 192.168.1.0/24.
List<String> subnetHosts(String ip) {
  final prefix = ip.substring(0, ip.lastIndexOf('.'));
  return [
    for (var host = 1; host < 255; host++)
      if ('$prefix.$host' != ip) '$prefix.$host',
  ];
}

Future<List<String>> _localAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return [
    for (final i in interfaces)
      for (final a in i.addresses)
        if (isPrivateLanAddress(a.address)) a.address,
  ];
}

Future<bool> _answersPing(String host) async {
  final client = HttpClient()..connectionTimeout = _scanTimeout;
  try {
    final request = await client
        .getUrl(Uri.parse('http://$host:$_navidromePort/ping'))
        .timeout(_scanTimeout);
    final response = await request.close().timeout(_scanTimeout);
    await response.drain<void>();
    return response.statusCode == 200;
  } on Exception {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Scans the phone's own /24 for something answering on Navidrome's port, then confirms
/// it with the real login so a stray device on port 4533 is never picked.
Future<String?> findServerOnLan(
  String user,
  String password, {
  UrlProbe probe = probeUrl,
  Future<List<String>> Function() addresses = _localAddresses,
  Future<bool> Function(String host) answers = _answersPing,
}) async {
  for (final own in await addresses()) {
    final hosts = subnetHosts(own);
    for (var i = 0; i < hosts.length; i += _scanBatchSize) {
      final batch = hosts.skip(i).take(_scanBatchSize).toList();
      final hits = await Future.wait(batch.map(answers));
      for (var j = 0; j < batch.length; j++) {
        if (!hits[j]) continue;
        final url = 'http://${batch[j]}:$_navidromePort';
        final result = await probe(url, user, password);
        if (result.isOk) return url;
      }
    }
  }
  return null;
}
