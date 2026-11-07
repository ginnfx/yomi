import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import '../subsonic_client.dart';

const Duration _reportsTimeout = Duration(seconds: 15);

/// What's wrong with a song. The wire names match the server's.
enum ReportKind {
  explicitWanted('explicit_wanted', 'Clean version, I want explicit'),
  coverMissing('cover_missing', 'Cover missing'),
  coverWrong('cover_wrong', 'Wrong cover'),
  missingSong('missing_song', 'Song to add'),
  other('other', 'Something else');

  const ReportKind(this.wire, this.label);

  final String wire;
  final String label;

  static ReportKind? fromWire(String? wire) {
    for (final kind in values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// A new report, before the server merges it with others about the same song.
@immutable
class ReportInput {
  const ReportInput({
    required this.kind,
    required this.artist,
    required this.title,
    this.songId,
    this.album,
    this.note = '',
  });

  factory ReportInput.forSong(Song song, ReportKind kind, {String note = ''}) =>
      ReportInput(
        kind: kind,
        artist: song.artist,
        title: song.title,
        songId: song.id,
        album: song.album,
        note: note,
      );

  final ReportKind kind;
  final String artist;
  final String title;
  final String? songId;
  final String? album;
  final String note;

  Map<String, Object?> toJson() => {
    'kind': kind.wire,
    'artist': artist,
    'title': title,
    'songId': ?songId,
    'album': ?album,
    if (note.trim().isNotEmpty) 'note': note.trim(),
  };
}

/// One song problem as the server keeps it.
@immutable
class SongReport {
  const SongReport({
    required this.id,
    required this.kind,
    required this.artist,
    required this.title,
    required this.status,
    required this.count,
    required this.updatedAt,
    this.songId,
    this.album,
    this.resolution,
    this.fixedSongId,
    this.isAuto = false,
    this.notes = const [],
  });

  static SongReport? tryParse(Map<String, dynamic> json) {
    final kind = ReportKind.fromWire(json['kind'] as String?);
    final id = json['id'] as String?;
    if (kind == null || id == null) return null;
    return SongReport(
      id: id,
      kind: kind,
      artist: (json['artist'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'open',
      count: (json['count'] as num?)?.toInt() ?? 1,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedMs'] as num?)?.toInt() ?? 0,
      ),
      songId: json['songId'] as String?,
      album: json['album'] as String?,
      resolution: json['resolution'] as String?,
      fixedSongId: json['fixedSongId'] as String?,
      isAuto: json['auto'] == true,
      notes: [
        for (final note
            in (json['notes'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>())
          '${note['user']}: ${note['text']}',
      ],
    );
  }

  final String id;
  final ReportKind kind;
  final String artist;
  final String title;
  final String status;
  final int count;
  final DateTime updatedAt;
  final String? songId;
  final String? album;
  final String? resolution;
  final String? fixedSongId;
  final bool isAuto;
  final List<String> notes;

  bool get isOpen => status == 'open';
}

/// The reports this account may see, and whether it may close them.
typedef ReportsPage = ({List<SongReport> reports, bool isAdmin});

/// A song people have asked for that the library doesn't have, shown to everyone. It says
/// how many people want it, never who.
@immutable
class WantedSong {
  const WantedSong({
    this.id = '',
    required this.artist,
    required this.title,
    required this.count,
  });

  /// Null when the server sent something that isn't a song, so one odd entry can't hide
  /// the rest.
  static WantedSong? tryParse(Map<String, dynamic> json) {
    final artist = json['artist'];
    final title = json['title'];
    if (artist is! String || title is! String) return null;
    return WantedSong(
      id: json['id'] is String ? json['id'] as String : '',
      artist: artist,
      title: title,
      count: (json['count'] as num?)?.toInt() ?? 1,
    );
  }

  /// The request's id, so it can be closed once the song is in the library. Empty from
  /// an older server.
  final String id;
  final String artist;
  final String title;
  final int count;
}

/// Talks to the upload service's report routes.
class ReportsApi {
  ReportsApi({
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

  Future<ReportsPage> list() async {
    final response = await _http
        .get(_uri('/v1/reports'))
        .timeout(_reportsTimeout);
    final json = _decode(response, 'Reports');
    return (
      reports: List<SongReport>.unmodifiable([
        for (final item
            in (json['reports'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>())
          ?SongReport.tryParse(item),
      ]),
      isAdmin: json['isAdmin'] == true,
    );
  }

  /// The songs everyone has asked for, most wanted first.
  Future<List<WantedSong>> wanted() async {
    final response = await _http
        .get(_uri('/v1/reports/wanted'))
        .timeout(_reportsTimeout);
    final json = _decode(response, 'The wanted list');
    return List.unmodifiable([
      for (final item
          in (json['songs'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>())
        ?WantedSong.tryParse(item),
    ]);
  }

  Future<void> add(ReportInput input) =>
      _send('POST', '/v1/reports', input.toJson());

  Future<void> close(String id, {required bool isFixed, String note = ''}) =>
      _send('PATCH', '/v1/reports/$id', {
        'status': isFixed ? 'resolved' : 'dismissed',
        'resolution': note,
      });

  /// Says a requested song is now in the library.
  Future<void> markAdded(String id, String songId) =>
      _send('POST', '/v1/reports/$id/added', {'songId': songId});

  /// Swaps the reported song for a better copy; the old file is archived.
  Future<void> replace(
    String id, {
    required String oldSongId,
    required String newSongId,
  }) => _send('POST', '/v1/reports/$id/replace', {
    'oldSongId': oldSongId,
    'newSongId': newSongId,
  });

  Future<void> _send(String method, String path, Object body) async {
    final request = http.Request(method, _uri(path))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    final streamed = await _http.send(request).timeout(_reportsTimeout);
    _decode(await http.Response.fromStream(streamed), path);
  }

  Map<String, dynamic> _decode(http.Response response, String what) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = '$what answered ${response.statusCode}';
      try {
        final error = (jsonDecode(response.body) as Map)['message'];
        if (error is String && error.isNotEmpty) message = error;
      } on FormatException {
        // Not JSON; the status code says enough.
      }
      throw http.ClientException(message);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : const {};
  }
}
