import 'dart:collection';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The server gave a clear answer: there is no picture for this cover. Trying again
/// right away won't help, unlike when the connection fails.
class CoverNotAvailable implements Exception {
  const CoverNotAvailable(this.reason, {this.isTransient = false});

  final String reason;

  /// A default image can be a temporary replica/catalog miss, not absent artwork.
  final bool isTransient;

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

const String _navidromeCoverPath = '/rest/getCoverArt';

/// Navidrome's generic blue record is a successful image response, not album art.
/// Exact bytes avoid mistaking a real blue album cover for the placeholder.
const int navidromePlaceholderBytes = 69228;
bool isNavidromePlaceholder(Uint8List bytes) =>
    bytes.length == navidromePlaceholderBytes &&
    sha256.convert(bytes).toString() ==
        '273a4dbd61dfbb0a12d5d8ffe780eb7a3d4d000bc9771c5411cc70ae4dfa8a1f';
const String _poolCoverPath = '/v1/pool/cover/';

/// Set once at startup to find the upload service's port for an address, so covers can
/// come from the shared pool. Left null, covers always come straight from Navidrome.
int? Function(String url)? sharedPoolPort;

/// The shared pool's address for a Navidrome cover address, or null for any other address.
/// The pool lives on the upload service, so it needs that service's port.
Uri? poolCoverUri(Uri navidrome, int uploadPort) {
  if (!navidrome.path.endsWith(_navidromeCoverPath)) return null;
  final id = navidrome.queryParameters['id'];
  if (id == null || id.isEmpty) return null;
  return navidrome.replace(
    port: uploadPort,
    path: '$_poolCoverPath${Uri.encodeComponent(id)}',
  );
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
    int? Function(String url)? uploadPortFor,
  }) : _uploadPortFor = uploadPortFor,
       _newClient = newClient ?? _defaultClient {
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
  final int? Function(String url)? _uploadPortFor;
  final Queue<Completer<void>> _waiting = Queue();
  bool _isPoolUnavailable = false;
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
      final pooled = await _fromPool(url, generation);
      if (pooled != null) return pooled;
      // The connection changed meanwhile, so this address may no longer be right.
      if (generation != _generation) {
        throw StateError('Cancelled while fetching: the connection changed.');
      }
      return await _fromAddress(Uri.parse(url));
    } finally {
      _finishTurn();
    }
  }

  Future<Uint8List> _fromAddress(Uri uri) async {
    final response = await _client.get(uri).timeout(requestTimeout);
    final status = response.statusCode;
    if (status >= 500 || status == 408 || status == 429) {
      throw HttpException('The server answered $status');
    }
    if (status != 200) throw CoverNotAvailable('the server answered $status');
    final bytes = response.bodyBytes;
    if (!looksLikeImage(bytes)) {
      throw const CoverNotAvailable('the answer was not a picture');
    }
    if (isNavidromePlaceholder(bytes)) {
      throw const CoverNotAvailable(
        'the server returned its default cover',
        isTransient: true,
      );
    }
    return bytes;
  }

  /// The picture from the shared pool, or null to ask Navidrome instead. Anything the
  /// pool gets wrong only costs one extra request, never a missing cover.
  Future<Uint8List?> _fromPool(String url, int generation) async {
    final portFor = _uploadPortFor;
    if (_isPoolUnavailable || portFor == null) return null;
    final uri = Uri.parse(url);
    final port = portFor(url);
    final pooled = port == null ? null : poolCoverUri(uri, port);
    if (pooled == null) return null;
    try {
      final response = await _client.get(pooled).timeout(requestTimeout);
      if (generation != _generation) return null;
      final bytes = response.bodyBytes;
      if (response.statusCode == 200 &&
          looksLikeImage(bytes) &&
          !isNavidromePlaceholder(bytes))
        return bytes;
      // A route the server doesn't have, or a pool it turned off, means no pool here.
      // A cover it says it doesn't have is just that one cover.
      final status = response.statusCode;
      // The redirect to the stored picture can 404 if it was just cleared out, which
      // says nothing about whether this server has a pool.
      final answeredBy = response is http.BaseResponseWithUrl
          ? (response as http.BaseResponseWithUrl).url
          : pooled;
      final isCoverRoute = answeredBy.path.startsWith(_poolCoverPath);
      final isMissingCover =
          status == 404 && response.body.contains('no such cover');
      if (isCoverRoute &&
          !isMissingCover &&
          (status == 404 || status == 405 || status == 503)) {
        _isPoolUnavailable = true;
      }
    } on TimeoutException {
      // A slow first fill is not a missing pool; just ask Navidrome this once.
    } on Exception {
      if (generation == _generation) _isPoolUnavailable = true;
    }
    return null;
  }

  void cancelAll() {
    _generation++;
    _isPoolUnavailable = false;
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
