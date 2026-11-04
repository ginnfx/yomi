import 'dart:convert';
import 'dart:io';

const Duration _roleTimeout = Duration(seconds: 3);

typedef RoleProbe = Future<bool> Function(String musicUrl, int uploadPort);

/// Asks the upload service whether this address is the read-only backup server. Anything
/// unclear counts as no, which only means an edit could be attempted and refused.
Future<bool> probeIsReplica(String musicUrl, int uploadPort) async {
  final client = HttpClient()..connectionTimeout = _roleTimeout;
  try {
    final uri = Uri.parse(musicUrl)
        .replace(port: uploadPort, path: '/health', query: '');
    final request = await client.getUrl(uri).timeout(_roleTimeout);
    final response = await request.close().timeout(_roleTimeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_roleTimeout);
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> && decoded['role'] == 'replica';
  } on Exception {
    return false;
  } finally {
    client.close(force: true);
  }
}
