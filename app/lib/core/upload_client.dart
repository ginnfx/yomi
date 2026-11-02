import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'subsonic_client.dart';

const int uploadPort = 4534;
const Duration _uploadTimeout = Duration(minutes: 30);

/// Where the Yomi upload service lives: same host as Navidrome, port [uploadPort].
Uri deriveUploadUri(String serverUrl, {int port = uploadPort}) {
  final base = Uri.parse(serverUrl.replaceAll(RegExp(r'/+$'), ''));
  return base.replace(port: port, path: '/upload');
}

class UploadException implements Exception {
  const UploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Streams one audio file to the Yomi upload service, reporting progress.
class UploadClient {
  UploadClient({
    required this.serverUrl,
    required SubsonicClient auth,
    int? uploadPortOverride,
  }) : _auth = auth,
       _port = uploadPortOverride ?? uploadPort;

  final String serverUrl;
  final SubsonicClient _auth;
  final int _port;

  /// Uploads [file]; [onProgress] receives values from 0.0 to 1.0.
  Future<void> upload(
    File file, {
    required void Function(double) onProgress,
  }) async {
    final length = await file.length();
    final name = _headerSafeName(file.path.split(Platform.pathSeparator).last);
    final boundary =
        'yomi${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="$name"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final total = head.length + length + tail.length;

    final uri = deriveUploadUri(
      serverUrl,
      port: _port,
    ).replace(queryParameters: _auth.authParams());
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(uri);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      request.contentLength = total;

      var sent = 0;
      void add(List<int> chunk) {
        request.add(chunk);
        sent += chunk.length;
        onProgress(sent / total);
      }

      add(head);
      await for (final chunk in file.openRead()) {
        add(chunk);
        await request.flush();
      }
      add(tail);

      final response = await request.close().timeout(_uploadTimeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw UploadException(_messageFrom(body, response.statusCode));
      }
      onProgress(1);
    } on SocketException {
      throw const UploadException(
        'Cannot reach the upload service. Is the server on?',
      );
    } on HttpException catch (error) {
      throw UploadException('Upload interrupted: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  static String _headerSafeName(String name) =>
      name.replaceAll(RegExp(r'[\r\n"\\]'), '_');

  static String _messageFrom(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['message'] is String) {
        return decoded['message'] as String;
      }
    } on FormatException {
      // fall through to the generic message
    }
    return 'Upload failed (HTTP $status).';
  }
}
