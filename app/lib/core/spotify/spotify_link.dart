import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'spotify_export.dart';

const Duration _timeout = Duration(seconds: 25);
const String _browserAgent = 'Mozilla/5.0';

/// The embed page shows about this many tracks at most.
const int _embedLimit = 100;
const int _maxPageBytes = 16 << 20;

/// Why a link couldn't be imported, in words to show.
class SpotifyLinkException implements Exception {
  const SpotifyLinkException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A playlist read from a public link. [mayBeIncomplete] is true when it stopped at
/// what Spotify's page shows, so the app can say so rather than pretend it's exact.
@immutable
class LinkedPlaylist {
  const LinkedPlaylist(this.playlist, {required this.mayBeIncomplete});

  final ExportPlaylist playlist;
  final bool mayBeIncomplete;
}

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9]{22}$');
final RegExp _nextData = RegExp(
  r'''<script\b[^>]*\bid=["']__NEXT_DATA__["'][^>]*>(.*?)</script>''',
  dotAll: true,
);

/// The playlist ID in a Spotify link or URI, or null if this isn't one. Only Spotify's own
/// site counts, so a pasted link can't make the app fetch anything else.
String? spotifyPlaylistId(String input) {
  final text = input.trim();
  if (text.startsWith('spotify:playlist:')) {
    final id = text.substring('spotify:playlist:'.length);
    return _idPattern.hasMatch(id) ? id : null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'https' || uri.host != 'open.spotify.com') {
    return null;
  }
  final parts = uri.pathSegments
      .where((part) => !part.startsWith('intl-') && part != 'embed')
      .toList();
  if (parts.length != 2 || parts.first != 'playlist') return null;
  return _idPattern.hasMatch(parts.last) ? parts.last : null;
}

/// Reads the track list out of Spotify's public embed page.
ExportPlaylist parseEmbedPage(String page) {
  final match = _nextData.firstMatch(page);
  if (match == null) {
    throw const SpotifyLinkException(
      "Spotify didn't show a track list. The playlist may be private.",
    );
  }
  try {
    final json = jsonDecode(match.group(1)!) as Map<String, dynamic>;
    final entity =
        json['props']['pageProps']['state']['data']['entity']
            as Map<String, dynamic>;
    final tracks = <ExportTrack>[];
    for (final item in (entity['trackList'] as List<dynamic>? ?? const [])) {
      if (item is! Map || item['title'] is! String) continue;
      final duration = item['duration'];
      tracks.add(
        ExportTrack(
          title: item['title'] as String,
          artist: item['subtitle'] is String ? item['subtitle'] as String : '',
          durationSeconds: duration is num
              ? (duration / Duration.millisecondsPerSecond).round()
              : null,
        ),
      );
    }
    if (tracks.isEmpty) {
      throw const SpotifyLinkException(
        'No tracks found. The playlist may be private or empty.',
      );
    }
    final name = entity['name'] ?? entity['title'];
    return ExportPlaylist(
      name: name is String ? name : 'Spotify playlist',
      tracks: tracks,
    );
  } on SpotifyLinkException {
    rethrow;
  } on Object catch (error) {
    debugPrint('Unexpected Spotify embed page: $error');
    throw const SpotifyLinkException(
      "Spotify's page has changed, so this link can't be read. "
      'A file from your Spotify data will still work.',
    );
  }
}

Future<List<int>> _readLimited(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > _maxPageBytes) {
      throw const SpotifyLinkException("That page is too large to read.");
    }
    bytes.addAll(chunk);
  }
  return bytes;
}

/// Fetches a public playlist by its link.
Future<LinkedPlaylist> fetchSpotifyPlaylist(
  String link, {
  http.Client? client,
}) async {
  final id = spotifyPlaylistId(link);
  if (id == null) {
    throw const SpotifyLinkException(
      'Paste a link like https://open.spotify.com/playlist/…',
    );
  }
  final List<int> bytes;
  try {
    final request = http.Request(
      'GET',
      Uri.https('open.spotify.com', '/embed/playlist/$id'),
    )..headers['User-Agent'] = _browserAgent;
    final response = await (client ?? http.Client())
        .send(request)
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw const SpotifyLinkException(
        "Spotify didn't share that playlist. It may be private.",
      );
    }
    bytes = await _readLimited(response.stream).timeout(_timeout);
  } on SpotifyLinkException {
    rethrow;
  } on Object catch (error) {
    debugPrint('Could not reach Spotify: $error');
    throw const SpotifyLinkException("Couldn't reach Spotify.");
  }
  final playlist = parseEmbedPage(utf8.decode(bytes));
  return LinkedPlaylist(
    playlist,
    mayBeIncomplete: playlist.tracks.length >= _embedLimit,
  );
}
