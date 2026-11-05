import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../subsonic_client.dart';
import 'play_history.dart';

const Duration _timeout = Duration(seconds: 30);

/// One play, with the names kept so it still counts once the song is gone from the library.
@immutable
class ListenEvent {
  const ListenEvent({
    required this.id,
    required this.songId,
    required this.artist,
    required this.title,
    required this.album,
    required this.at,
    required this.kind,
    required this.seconds,
    this.genre,
  });

  factory ListenEvent.fromJson(Map<String, dynamic> json) => ListenEvent(
    id: json['id'] as String,
    songId: json['songId'] as String,
    artist: (json['artist'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    album: (json['album'] as String?) ?? '',
    genre: json['genre'] as String?,
    at: DateTime.fromMillisecondsSinceEpoch((json['atMs'] as num).toInt()),
    kind: json['kind'] == 'skipped' ? PlayKind.skipped : PlayKind.completed,
    seconds: (json['seconds'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String songId;
  final String artist;
  final String title;
  final String album;
  final String? genre;
  final DateTime at;
  final PlayKind kind;
  final int seconds;

  Map<String, Object?> toJson() => {
    'id': id,
    'songId': songId,
    'artist': artist,
    'title': title,
    'album': album,
    'genre': ?genre,
    'atMs': at.millisecondsSinceEpoch,
    'kind': kind.name,
    'seconds': seconds,
  };
}

/// A page of plays from the server, and where to continue from.
@immutable
class HistoryPage {
  const HistoryPage(this.events, this.next);

  final List<ListenEvent> events;
  final int next;
}

/// Saves plays on the upload service, so they're shared between your devices.
class HistoryApi {
  HistoryApi({
    required this.serverUrl,
    required this.auth,
    required this.port,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String serverUrl;
  final SubsonicClient auth;
  final int port;
  final http.Client _http;

  Uri _uri(String path, [Map<String, String> extra = const {}]) =>
      Uri.parse(serverUrl.replaceAll(RegExp(r'/+$'), '')).replace(
        port: port,
        path: path,
        queryParameters: {...auth.authParams(stable: true), ...extra},
      );

  void _check(http.Response response) {
    if (response.statusCode != 200) {
      throw http.ClientException('History answered ${response.statusCode}');
    }
  }

  Future<void> upload(List<ListenEvent> events) async {
    final response = await _http
        .post(
          _uri('/v1/history'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'events': [for (final event in events) event.toJson()],
          }),
        )
        .timeout(_timeout);
    _check(response);
  }

  Future<HistoryPage> read(int after) async {
    final response = await _http
        .get(_uri('/v1/history', {'after': '$after'}))
        .timeout(_timeout);
    _check(response);
    final json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return HistoryPage(
      ((json['events'] as List<dynamic>?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(ListenEvent.fromJson)
          .toList(growable: false),
      (json['next'] as num?)?.toInt() ?? after,
    );
  }

  Future<Map<String, dynamic>> readImported() async {
    final response = await _http
        .get(_uri('/v1/history/imported'))
        .timeout(_timeout);
    _check(response);
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> saveImported(String body) async {
    final response = await _http
        .put(
          _uri('/v1/history/imported'),
          headers: const {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(_timeout * 2);
    _check(response);
  }
}
