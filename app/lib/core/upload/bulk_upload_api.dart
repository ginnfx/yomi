import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../subsonic_client.dart';

const int uploadPort = 4534;
const Duration _connectTimeout = Duration(seconds: 15);
const Duration _stallTimeout = Duration(seconds: 60);
const Duration _earlyAnswerWait = Duration(seconds: 3);
const Duration _responseTimeout = Duration(minutes: 5);
const Duration _defaultRetryAfter = Duration(seconds: 5);

/// The server is busy; try this upload again after [after].
class UploadRetryLater implements Exception {
  const UploadRetryLater(this.after);

  final Duration after;
}

/// The server can't be reached right now.
class UploadUnreachable implements Exception {
  const UploadUnreachable();
}

/// The server doesn't have these routes yet, so it needs updating.
class UploadRouteMissing implements Exception {
  const UploadRouteMissing();
}

/// This is the read-only backup server, which can't take uploads.
class UploadReadOnly implements Exception {
  const UploadReadOnly();
}

class UploadAuthFailed implements Exception {
  const UploadAuthFailed();
}

class UploadStorageFull implements Exception {
  const UploadStorageFull();
}

/// The server refused this particular file. Retrying won't help.
class UploadRejected implements Exception {
  const UploadRejected(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The file arrived damaged. Sending it again usually works.
class UploadCorrupted implements Exception {
  const UploadCorrupted();
}

enum PutResult { stored, duplicate }

/// What the queue needs from the server. A separate type so it can be faked.
abstract interface class UploadTransport {
  Future<Set<String>> check(List<String> hashes);

  Future<PutResult> put(
    File file, {
    required String sha256,
    required String name,
    required void Function(double progress) onProgress,
  });
}

class BulkUploadApi implements UploadTransport {
  BulkUploadApi({
    required this.serverUrl,
    required this.auth,
    this.port = uploadPort,
  });

  final String serverUrl;
  final SubsonicClient auth;
  final int port;

  Uri _uri(String path, [Map<String, String> extra = const {}]) =>
      Uri.parse(serverUrl.replaceAll(RegExp(r'/+$'), '')).replace(
        port: port,
        path: path,
        queryParameters: {...auth.authParams(), ...extra},
      );

  HttpClient _client() => HttpClient()..connectionTimeout = _connectTimeout;

  @override
  Future<Set<String>> check(List<String> hashes) async {
    final client = _client();
    try {
      final request = await client.postUrl(_uri('/v1/check'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'hashes': hashes}));
      final response = await request.close().timeout(_responseTimeout);
      final body = await response.transform(utf8.decoder).join();
      _throwForStatus(response, body);
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      return (decoded['known'] as List<dynamic>).cast<String>().toSet();
    } on SocketException {
      throw const UploadUnreachable();
    } on HttpException {
      throw const UploadUnreachable();
    } on TimeoutException {
      throw const UploadUnreachable();
    } on FormatException {
      // Something else answered, such as a Wi-Fi login page.
      throw const UploadUnreachable();
    } on TypeError {
      throw const UploadUnreachable();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<PutResult> put(
    File file, {
    required String sha256,
    required String name,
    required void Function(double progress) onProgress,
  }) async {
    final length = await file.length();
    final client = _client();
    try {
      final request = await client.putUrl(
        _uri('/v1/upload/$sha256', {'name': name}),
      );
      request.contentLength = length;
      var sent = 0;
      try {
        await for (final chunk in file.openRead()) {
          request.add(chunk);
          await request.flush().timeout(_stallTimeout);
          sent += chunk.length;
          onProgress(length == 0 ? 1 : sent / length);
        }
      } on SocketException {
        await _throwFileSpecificFailure(request, client);
        rethrow;
      } on HttpException {
        await _throwFileSpecificFailure(request, client);
        rethrow;
      }
      final response = await request.close().timeout(_responseTimeout);
      final body = await response.transform(utf8.decoder).join();
      _throwForStatus(response, body);
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      return decoded['status'] == 'duplicate'
          ? PutResult.duplicate
          : PutResult.stored;
    } on SocketException {
      throw const UploadUnreachable();
    } on HttpException {
      throw const UploadUnreachable();
    } on TimeoutException {
      throw const UploadUnreachable();
    } on FormatException {
      // Something else answered, such as a Wi-Fi login page.
      throw const UploadUnreachable();
    } on TypeError {
      throw const UploadUnreachable();
    } finally {
      client.close(force: true);
    }
  }

  /// The server may refuse a file (too big, storage full) before reading the body and
  /// hang up, sometimes taking its answer with it. If it still answers a small request,
  /// the connection isn't what failed: this file is, and retrying it would loop forever.
  Future<void> _throwFileSpecificFailure(
    HttpClientRequest request,
    HttpClient client,
  ) async {
    await _throwEarlyAnswer(request);
    if (await _serverAnswers(client)) {
      throw const UploadRejected(
        'The server turned this file away (too large, or no room left).',
      );
    }
  }

  Future<bool> _serverAnswers(HttpClient client) async {
    try {
      final probe = await client.postUrl(_uri('/v1/check'));
      probe.headers.contentType = ContentType.json;
      probe.write(jsonEncode({'hashes': <String>[]}));
      final response = await probe.close().timeout(_earlyAnswerWait);
      await response.drain<void>();
      return true;
    } on Object {
      return false;
    }
  }

  static Future<void> _throwEarlyAnswer(HttpClientRequest request) async {
    final HttpClientResponse response;
    final String body;
    try {
      response = await request.done.timeout(_earlyAnswerWait);
      body = await response.transform(utf8.decoder).join();
    } on Object {
      return; // no usable answer: it really was a dropped connection
    }
    _throwForStatus(response, body);
  }

  static void _throwForStatus(HttpClientResponse response, String body) {
    switch (response.statusCode) {
      case HttpStatus.ok || HttpStatus.created:
        return;
      case HttpStatus.notFound || HttpStatus.methodNotAllowed:
        throw const UploadRouteMissing();
      case HttpStatus.tooManyRequests:
        final seconds = int.tryParse(
          response.headers.value(HttpHeaders.retryAfterHeader) ?? '',
        );
        throw UploadRetryLater(
          seconds == null ? _defaultRetryAfter : Duration(seconds: seconds),
        );
      case HttpStatus.unauthorized:
        throw const UploadAuthFailed();
      case HttpStatus.forbidden:
        throw const UploadReadOnly();
      case HttpStatus.requestEntityTooLarge:
        throw UploadRejected(_messageFrom(body, response.statusCode));
      case HttpStatus.insufficientStorage:
        throw const UploadStorageFull();
      case HttpStatus.unprocessableEntity:
        throw const UploadCorrupted();
      case HttpStatus.badGateway || HttpStatus.serviceUnavailable:
        throw const UploadUnreachable();
      default:
        throw UploadRejected(_messageFrom(body, response.statusCode));
    }
  }

  static String _messageFrom(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['message'] is String) {
        return decoded['message'] as String;
      }
    } on FormatException {
      // Fall through to the generic message.
    }
    return 'Upload failed (HTTP $status).';
  }
}
