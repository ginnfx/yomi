import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import '../subsonic_client.dart';
import 'spotify_export.dart';
import 'track_matcher.dart';

const Duration _timeout = Duration(seconds: 30);

/// One track in its place. [songId] is what it plays, once there's a song for it.
@immutable
class ImportEntry {
  const ImportEntry({
    required this.title,
    required this.artist,
    this.album,
    this.durationSeconds,
    this.songId,
    this.isUserChoice = false,
  });

  factory ImportEntry.fromJson(Map<String, dynamic> json) => ImportEntry(
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String?,
    durationSeconds: (json['duration'] as num?)?.toInt(),
    songId: json['songId'] as String?,
    isUserChoice: json['userChoice'] == true,
  );

  final String title;
  final String artist;
  final String? album;
  final int? durationSeconds;
  final String? songId;

  /// You chose this song by hand, so automatic matching leaves it alone.
  final bool isUserChoice;

  ExportTrack get asTrack => ExportTrack(
    title: title,
    artist: artist,
    album: album,
    durationSeconds: durationSeconds,
  );

  ImportEntry withSong(String? id, {bool isUserChoice = false}) => ImportEntry(
    title: title,
    artist: artist,
    album: album,
    durationSeconds: durationSeconds,
    songId: id,
    isUserChoice: isUserChoice,
  );

  Map<String, Object?> toJson() => {
    'title': title,
    'artist': artist,
    'album': album,
    'duration': durationSeconds,
    'songId': songId,
    'userChoice': isUserChoice,
  };
}

/// A playlist from elsewhere in its exact order, including songs not in the library yet.
@immutable
class ImportedPlaylist {
  const ImportedPlaylist({
    required this.id,
    required this.name,
    required this.entries,
  });

  factory ImportedPlaylist.fromJson(Map<String, dynamic> json) =>
      ImportedPlaylist(
        id: json['id'] as String,
        name: json['name'] as String,
        entries: List.unmodifiable(
          (json['entries'] as List<dynamic>).cast<Map<String, dynamic>>().map(
            ImportEntry.fromJson,
          ),
        ),
      );

  final String id;
  final String name;
  final List<ImportEntry> entries;

  int get matchedCount => entries.where((e) => e.songId != null).length;

  ImportedPlaylist withEntries(List<ImportEntry> next) =>
      ImportedPlaylist(id: id, name: name, entries: List.unmodifiable(next));

  /// Fills empty places with songs now in the library, as after you upload a missing one.
  /// A sure match only, so nothing changes without you knowing.
  ImportedPlaylist rematched(TrackMatcher matcher) {
    var isChanged = false;
    final next = [
      for (final entry in entries)
        if (entry.songId == null && !entry.isUserChoice)
          () {
            final found = matcher.match(entry.asTrack);
            if (found.status != MatchStatus.matched) return entry;
            isChanged = true;
            return entry.withSong(found.song!.id);
          }()
        else
          entry,
    ];
    return isChanged ? withEntries(next) : this;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'entries': [for (final entry in entries) entry.toJson()],
  };
}

/// Matches a playlist against the library, ready for reviewing.
List<ReviewedTrack> reviewTracks(List<ExportTrack> tracks, List<Song> library) {
  final matcher = TrackMatcher(library);
  return [
    for (final track in tracks) ReviewedTrack(track, matcher.match(track)),
  ];
}

@immutable
class ReviewedTrack {
  const ReviewedTrack(this.track, this.match);

  final ExportTrack track;
  final TrackMatch match;
}

/// Stores imported playlists on the server, so they're on every device.
class ImportsApi {
  ImportsApi({
    required this.serverUrl,
    required this.auth,
    required this.port,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String serverUrl;
  final SubsonicClient auth;
  final int port;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse(serverUrl.replaceAll(RegExp(r'/+$'), ''))
      .replace(
        port: port,
        path: path,
        queryParameters: auth.authParams(stable: true),
      );

  void _check(http.Response response) {
    if (response.statusCode != 200) {
      throw http.ClientException('Imports answered ${response.statusCode}');
    }
  }

  Future<List<ImportedPlaylist>> list() async {
    final response = await _http.get(_uri('/v1/imports')).timeout(_timeout);
    _check(response);
    final json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return [
      for (final item
          in (json['imports'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>())
        ImportedPlaylist.fromJson(item),
    ];
  }

  Future<void> save(ImportedPlaylist playlist) async {
    final response = await _http
        .put(
          _uri('/v1/imports/${playlist.id}'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(playlist.toJson()),
        )
        .timeout(_timeout);
    _check(response);
  }

  Future<void> delete(String id) async {
    final response = await _http
        .delete(_uri('/v1/imports/$id'))
        .timeout(_timeout);
    _check(response);
  }
}
