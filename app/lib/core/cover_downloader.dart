import 'dart:collection';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The server gave a clear answer: there is no picture for this cover. Trying again
/// right away won't help, unlike when the connection fails.
class CoverNotAvailable implements Exception {
  const CoverNotAvailable(this.reason);

  final String reason;

  @override
  String toString() => 'No cover available: $reason';
}

/// Whether [bytes] start like a picture, rather than an error message from a server.
bool looksLikeImage(Uint8List bytes) {
  bool startsWith(List<int> prefix, [int at = 0]) {
    if (bytes.length < at + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[at + i] != prefix[i]) return false;
    }
    return true;
  }

  return startsWith(const [0xFF, 0xD8, 0xFF]) || // JPEG
      startsWith(const [0x89, 0x50, 0x4E, 0x47]) || // PNG
      startsWith(const [0x47, 0x49, 0x46]) || // GIF
      startsWith(const [0x42, 0x4D]) || // BMP
      startsWith(const [0x52, 0x49, 0x46, 0x46]) || // WebP
      startsWith(const [0x66, 0x74, 0x79, 0x70], 4); // HEIC and AVIF
}

/// Fetches covers a few at a time, as the server is a small machine. The newest request
/// goes first, so covers on screen don't wait behind ones already scrolled past.
///
/// [cancelAll] really does drop every request, including ones stuck on an address that no
/// longer works and ones still waiting for a turn, so they can't hold back new ones.
class CoverDownloader {
  CoverDownloader({
    http.Client Function()? newClient,
    this.maxAtOnce = 6,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _newClient = newClient ?? _defaultClient {
    _client = _newClient();
  }

  /// How long to wait for the server to accept a connection.
  static const Duration _connectTimeout = Duration(seconds: 8);

  static http.Client _defaultClient() =>
      IOClient(HttpClient()..connectionTimeout = _connectTimeout);

  final http.Client Function() _newClient;
  final int maxAtOnce;

  /// Starts once a request has its turn, so waiting behind others doesn't count.
  final Duration requestTimeout;
  final Queue<Completer<void>> _waiting = Queue();
  late http.Client _client;
  int _active = 0;
  int _generation = 0;

  /// Whether any download is running or waiting.
  bool get isBusy => _active > 0;

  Future<Uint8List> fetch(String url) async {
    final generation = _generation;
    await _takeTurn();
    try {
      if (generation != _generation) {
        throw StateError('Cancelled while waiting: the connection changed.');
      }
      final response = await _client
          .get(Uri.parse(url))
          .timeout(requestTimeout);
      final status = response.statusCode;
      if (status >= 500 || status == 408 || status == 429) {
        throw HttpException('The server answered $status');
      }
      if (status != 200) throw CoverNotAvailable('the server answered $status');
      final bytes = response.bodyBytes;
      if (!looksLikeImage(bytes)) {
        throw const CoverNotAvailable('the answer was not a picture');
      }
      return bytes;
    } finally {
      _finishTurn();
    }
  }

  void cancelAll() {
    _generation++;
    final old = _client;
    _client = _newClient();
    old.close();
  }

  Future<void> _takeTurn() async {
    if (_active < maxAtOnce) {
      _active++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future; // The turn is handed over with _active already counted.
  }

  void _finishTurn() {
    if (_waiting.isEmpty) {
      _active--;
    } else {
      _waiting.removeLast().complete();
    }
  }
}
