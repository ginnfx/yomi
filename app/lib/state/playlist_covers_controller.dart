import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/subsonic_client.dart';

const Duration _timeout = Duration(seconds: 30);

/// Pictures people chose for their playlists, kept on the upload service.
class PlaylistCoversApi {
  PlaylistCoversApi({
    required this.serverUrl,
    required this.auth,
    required this.port,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String serverUrl;
  final SubsonicClient auth;
  final int port;
  final http.Client _http;

  Uri uri(String path, [Map<String, String> extra = const {}]) =>
      Uri.parse(serverUrl.replaceAll(RegExp(r'/+$'), '')).replace(
        port: port,
        path: path,
        queryParameters: {...auth.authParams(stable: true), ...extra},
      );

  Future<Map<String, int>> versions() async {
    final response = await _http
        .get(uri('/v1/playlist-covers'))
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException('Covers answered ${response.statusCode}');
    }
    final json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return {
      for (final entry
          in ((json['covers'] as Map<String, dynamic>?) ?? const {}).entries)
        entry.key: (entry.value as num).toInt(),
    };
  }

  Future<int> save(String playlistId, Uint8List image) async {
    final response = await _http
        .put(uri('/v1/playlists/$playlistId/cover'), body: image)
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw PlaylistCoverException(_reason(response));
    }
    final json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return (json['version'] as num).toInt();
  }

  Future<void> remove(String playlistId) async {
    final response = await _http
        .delete(uri('/v1/playlists/$playlistId/cover'))
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw PlaylistCoverException(_reason(response));
    }
  }

  static String _reason(http.Response response) {
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, dynamic> && json['message'] is String) {
        return json['message'] as String;
      }
    } on FormatException {
      // Falls through to the plain message.
    }
    return "Couldn't change the picture (${response.statusCode}).";
  }
}

class PlaylistCoverException implements Exception {
  const PlaylistCoverException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Which playlists have a chosen picture, and where to load it from.
class PlaylistCoversController extends ChangeNotifier {
  PlaylistCoversApi? _api;
  Map<String, int> _versions = const {};

  void attach(PlaylistCoversApi? api) {
    _api = api;
    _versions = const {};
    notifyListeners();
    if (api != null) unawaited(refresh());
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    try {
      final versions = await api.versions();
      if (!identical(api, _api)) return;
      _versions = Map.unmodifiable(versions);
      notifyListeners();
    } on Object catch (error) {
      debugPrint('Could not load playlist pictures: $error');
    }
  }

  bool hasCover(String playlistId) => _versions.containsKey(playlistId);

  /// The chosen picture's address, or null to use the usual cover.
  String? urlFor(String playlistId) {
    final api = _api;
    final version = _versions[playlistId];
    if (api == null || version == null) return null;
    return api.uri('/v1/playlists/$playlistId/cover', {
      'v': '$version',
    }).toString();
  }

  /// Throws [PlaylistCoverException] with a reason to show, such as not being the owner.
  Future<void> setCover(String playlistId, Uint8List image) async {
    final api = _api;
    if (api == null) throw const PlaylistCoverException('Not signed in.');
    final version = await api.save(playlistId, image);
    _versions = Map.unmodifiable({..._versions, playlistId: version});
    notifyListeners();
  }

  Future<void> removeCover(String playlistId) async {
    final api = _api;
    if (api == null) throw const PlaylistCoverException('Not signed in.');
    await api.remove(playlistId);
    _versions = Map.unmodifiable({
      for (final entry in _versions.entries)
        if (entry.key != playlistId) entry.key: entry.value,
    });
    notifyListeners();
  }
}
