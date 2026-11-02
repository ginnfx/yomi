import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'subsonic_client.dart';

class LyricLine {
  const LyricLine(this.start, this.text);

  final Duration? start;
  final String text;
}

class Lyrics {
  const Lyrics(this.lines, {required this.isSynced});

  final List<LyricLine> lines;
  final bool isSynced;

  static final RegExp _stamp = RegExp(
    r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]',
  );

  factory Lyrics.parseLrc(String text) {
    final lines = <LyricLine>[];
    for (final raw in text.split('\n')) {
      final stamps = _stamp.allMatches(raw).toList();
      if (stamps.isEmpty) continue;
      final body = raw.substring(stamps.last.end).trim();
      for (final m in stamps) {
        final fraction = m.group(3);
        final ms = fraction == null
            ? 0
            : int.parse(fraction.padRight(3, '0').substring(0, 3));
        lines.add(
          LyricLine(
            Duration(
              minutes: int.parse(m.group(1)!),
              seconds: int.parse(m.group(2)!),
              milliseconds: ms,
            ),
            body,
          ),
        );
      }
    }
    lines.sort((a, b) => a.start!.compareTo(b.start!));
    return Lyrics(lines, isSynced: lines.isNotEmpty);
  }

  factory Lyrics.parsePlain(String text) => Lyrics([
    for (final l in text.trim().split('\n')) LyricLine(null, l.trim()),
  ], isSynced: false);

  /// Index of the line being sung at [position], or -1 before the first line.
  int activeIndex(Duration position) {
    var active = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].start! <= position) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }
}

/// Finds lyrics: the server first (embedded or .lrc files), then the public LRCLIB database.
class LyricsService {
  LyricsService({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;
  final Map<String, Future<Lyrics?>> _cache = {};

  Future<Lyrics?> forSong(SubsonicClient client, Song song) =>
      _cache.putIfAbsent(song.id, () => _find(client, song));

  Future<Lyrics?> _find(SubsonicClient client, Song song) async {
    try {
      final fromServer = await client.lyricsFor(song.id);
      if (fromServer != null) return fromServer;
    } on Object {
      // The server may be older or offline; the public lookup below still works.
    }
    try {
      final uri = Uri.https('lrclib.net', '/api/get', {
        'artist_name': song.artist,
        'track_name': song.title,
        if (song.durationSeconds > 0) 'duration': '${song.durationSeconds}',
      });
      final response = await _http
          .get(uri, headers: {'User-Agent': 'Yomi'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final synced = json['syncedLyrics'] as String?;
      if (synced != null && synced.trim().isNotEmpty)
        return Lyrics.parseLrc(synced);
      final plain = json['plainLyrics'] as String?;
      if (plain != null && plain.trim().isNotEmpty)
        return Lyrics.parsePlain(plain);
    } on Object {
      return null;
    }
    return null;
  }
}
