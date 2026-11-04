import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import '../search_index.dart';
import '../subsonic_client.dart';

const Duration _tagsTimeout = Duration(seconds: 30);
const Duration _interpretTimeout = Duration(seconds: 35);

/// What a phrase like "sad songs for a rainy night" means, applied to the local library.
@immutable
class SearchFilters {
  const SearchFilters({
    this.moods = const [],
    this.energy,
    this.genres = const [],
    this.artists = const [],
    this.excludeMoods = const [],
  });

  factory SearchFilters.fromJson(Map<String, dynamic> json) => SearchFilters(
    moods: _strings(json['moods']),
    energy: json['energy'] as String?,
    genres: _strings(json['genres']),
    artists: _strings(json['artists']),
    excludeMoods: _strings(json['excludeMoods']),
  );

  final List<String> moods;
  final String? energy;
  final List<String> genres;
  final List<String> artists;
  final List<String> excludeMoods;

  bool get isEmpty =>
      moods.isEmpty &&
      energy == null &&
      genres.isEmpty &&
      artists.isEmpty &&
      excludeMoods.isEmpty;

  SearchFilters without({
    String? mood,
    String? genre,
    String? artist,
    String? excludeMood,
    bool energy = false,
  }) => SearchFilters(
    moods: moods.where((m) => m != mood).toList(),
    energy: energy ? null : this.energy,
    genres: genres.where((g) => g != genre).toList(),
    artists: artists.where((a) => a != artist).toList(),
    excludeMoods: excludeMoods.where((m) => m != excludeMood).toList(),
  );

  /// Whether [song] fits. A song the AI hasn't labelled can't match a mood.
  bool matches(Song song, SongTag? tag) {
    if (artists.isNotEmpty && !artists.contains(song.artist)) return false;
    if (genres.isNotEmpty) {
      final genre = normalizeForSearch(song.genre ?? '');
      if (!genres.any((g) => normalizeForSearch(g) == genre)) return false;
    }
    if (moods.isNotEmpty && !(tag?.moods.any(moods.contains) ?? false)) {
      return false;
    }
    if (energy != null && tag?.energy != energy) return false;
    if (tag?.moods.any(excludeMoods.contains) ?? false) return false;
    return true;
  }
}

/// What the AI said about a song.
@immutable
class SongTag {
  const SongTag({this.moods = const [], this.energy});

  factory SongTag.fromJson(Map<String, dynamic> json) => SongTag(
    moods: _strings(json['moods']),
    energy: json['energy'] as String?,
  );

  final List<String> moods;
  final String? energy;

  Map<String, Object?> toJson() => {'moods': moods, 'energy': energy};
}

List<String> _strings(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];

/// The same song gets the same key on every device, however its ID changes.
String songTagKey(String artist, String title) =>
    '${normalizeForSearch(artist)}|${normalizeForSearch(title)}';

/// Labels from the server, or null when nothing changed since [etag].
@immutable
class TagsReply {
  const TagsReply({
    required this.isAvailable,
    required this.body,
    required this.etag,
  });

  final bool isAvailable;
  final String body;
  final String? etag;
}

/// Talks to the upload service's AI routes. The AI key stays on the server.
class AiApi {
  AiApi({
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

  /// Null means the labels haven't changed.
  Future<TagsReply?> tags({String? etag}) async {
    final response = await _http
        .get(_uri('/v1/tags'), headers: {'If-None-Match': ?etag})
        .timeout(_tagsTimeout);
    if (response.statusCode == 304) return null;
    if (response.statusCode != 200) {
      throw http.ClientException('Labels answered ${response.statusCode}');
    }
    final body = utf8.decode(response.bodyBytes);
    final json = jsonDecode(body) as Map<String, dynamic>;
    return TagsReply(
      isAvailable: json['available'] == true,
      body: body,
      etag: response.headers['etag'],
    );
  }

  Future<void> queueSongs(List<Map<String, String>> songs) async {
    final response = await _http
        .post(
          _uri('/v1/tags/songs'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'songs': songs}),
        )
        .timeout(_tagsTimeout);
    if (response.statusCode != 200) {
      throw http.ClientException('Queue answered ${response.statusCode}');
    }
  }

  Future<SearchFilters> interpret(String query) async {
    final response = await _http
        .post(
          _uri('/v1/search/interpret'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'query': query}),
        )
        .timeout(_interpretTimeout);
    if (response.statusCode != 200) {
      throw http.ClientException('Interpret answered ${response.statusCode}');
    }
    return SearchFilters.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  }
}
