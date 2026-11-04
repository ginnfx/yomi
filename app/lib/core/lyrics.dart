import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'subsonic_client.dart';

const Duration _lookupTimeout = Duration(seconds: 8);

/// How long "this song has no lyrics" is believed before asking again.
const Duration kNoLyricsRetryAfter = Duration(days: 7);

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
  static final RegExp _offsetTag = RegExp(
    r'^\[offset:\s*([+-]?\d+)\s*\]',
    caseSensitive: false,
  );

  factory Lyrics.fromJson(Map<String, dynamic> json) {
    final rawLines = json['lines'] as List<dynamic>;
    return Lyrics([
      for (final line in rawLines.cast<Map<String, dynamic>>())
        LyricLine(
          line['ms'] == null
              ? null
              : Duration(milliseconds: (line['ms'] as num).toInt()),
          line['text'] as String,
        ),
    ], isSynced: json['synced'] as bool);
  }

  Map<String, Object?> toJson() => {
    'synced': isSynced,
    'lines': [
      for (final line in lines)
        {'ms': line.start?.inMilliseconds, 'text': line.text},
    ],
  };

  /// Moves every line earlier by [offsetMs]; a negative offset moves them later.
  /// Both LRC and OpenSubsonic define a positive offset as "appear sooner".
  static Duration applyOffset(Duration start, int offsetMs) {
    final shifted = start.inMilliseconds - offsetMs;
    return Duration(milliseconds: shifted < 0 ? 0 : shifted);
  }

  factory Lyrics.parseLrc(String text) {
    final lines = <LyricLine>[];
    final rawLines = text.split('\n');
    final offsetMs =
        rawLines
            .map((raw) => _offsetTag.firstMatch(raw.trim())?.group(1))
            .whereType<String>()
            .map(int.parse)
            .firstOrNull ??
        0;
    for (final raw in rawLines) {
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
            applyOffset(
              Duration(
                minutes: int.parse(m.group(1)!),
                seconds: int.parse(m.group(2)!),
                milliseconds: ms,
              ),
              offsetMs,
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

/// Remembers lookups on disk so lyrics keep working offline and survive restarts.
class LyricsStore {
  LyricsStore(this.directory, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Directory directory;
  final DateTime Function() _now;

  File _fileFor(String songId) =>
      File('${directory.path}/${sha1.convert(utf8.encode(songId))}.json');

  /// Returns the saved answer, or null when there is nothing current to go on.
  Future<LyricsLookup?> read(String songId) async {
    final file = _fileFor(songId);
    try {
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return null;
      final lyrics = json['lyrics'];
      if (lyrics is Map<String, dynamic>) {
        return LyricsLookup.found(Lyrics.fromJson(lyrics));
      }
      final checkedAt = DateTime.fromMillisecondsSinceEpoch(
        (json['checkedAtMs'] as num).toInt(),
      );
      final isCurrent = _now().difference(checkedAt) < kNoLyricsRetryAfter;
      return isCurrent ? const LyricsLookup.none() : null;
    } on Object catch (error) {
      // A damaged entry only costs one more lookup.
      debugPrint('Ignoring saved lyrics for $songId: $error');
      return null;
    }
  }

  Future<void> write(String songId, LyricsLookup lookup) async {
    final file = _fileFor(songId);
    final temp = File('${file.path}.tmp');
    try {
      await directory.create(recursive: true);
      await temp.writeAsString(
        jsonEncode({
          'lyrics': lookup.lyrics?.toJson(),
          'checkedAtMs': _now().millisecondsSinceEpoch,
        }),
      );
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save lyrics for $songId: $error');
    }
  }
}

/// The result of asking for lyrics. Only [isCertain] answers are worth remembering:
/// a network failure says nothing about whether the song has lyrics.
class LyricsLookup {
  const LyricsLookup.found(Lyrics this.lyrics) : isCertain = true;
  const LyricsLookup.none() : lyrics = null, isCertain = true;
  const LyricsLookup.unknown() : lyrics = null, isCertain = false;

  final Lyrics? lyrics;
  final bool isCertain;
}

/// Finds lyrics: saved copy first, then the server (embedded or .lrc files),
/// then the public LRCLIB database.
class LyricsService {
  LyricsService({http.Client? httpClient, this.store})
    : _http = httpClient ?? http.Client();

  final http.Client _http;
  final LyricsStore? store;
  final Map<String, Future<Lyrics?>> _cache = {};

  Future<Lyrics?> forSong(SubsonicClient client, Song song) =>
      _cache.putIfAbsent(song.id, () => _resolve(client, song));

  Future<Lyrics?> _resolve(SubsonicClient client, Song song) async {
    final saved = await store?.read(song.id);
    if (saved != null) return saved.lyrics;
    final lookup = await _find(client, song);
    if (lookup.isCertain) {
      await store?.write(song.id, lookup);
    } else {
      // Leave no memory of a failed lookup, so the next attempt asks again.
      _cache.remove(song.id);
    }
    return lookup.lyrics;
  }

  Future<LyricsLookup> _find(SubsonicClient client, Song song) async {
    var isServerCertain = true;
    try {
      final fromServer = await client.lyricsFor(song.id);
      if (fromServer != null) return LyricsLookup.found(fromServer);
    } on Object catch (error) {
      // The server may be older or offline; the public lookup below still works.
      debugPrint('Server lyrics lookup failed: $error');
      isServerCertain = false;
    }
    final public = await _findPublic(song);
    if (public.lyrics != null) return public;
    return public.isCertain && isServerCertain
        ? const LyricsLookup.none()
        : const LyricsLookup.unknown();
  }

  Future<LyricsLookup> _findPublic(Song song) async {
    try {
      final uri = Uri.https('lrclib.net', '/api/get', {
        'artist_name': song.artist,
        'track_name': song.title,
        if (song.durationSeconds > 0) 'duration': '${song.durationSeconds}',
      });
      final response = await _http
          .get(uri, headers: {'User-Agent': 'Yomi'})
          .timeout(_lookupTimeout);
      if (response.statusCode == 404) return const LyricsLookup.none();
      if (response.statusCode != 200) return const LyricsLookup.unknown();
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final synced = json['syncedLyrics'] as String?;
      if (synced != null && synced.trim().isNotEmpty) {
        return LyricsLookup.found(Lyrics.parseLrc(synced));
      }
      final plain = json['plainLyrics'] as String?;
      if (plain != null && plain.trim().isNotEmpty) {
        return LyricsLookup.found(Lyrics.parsePlain(plain));
      }
      return const LyricsLookup.none();
    } on Object catch (error) {
      debugPrint('Public lyrics lookup failed: $error');
      return const LyricsLookup.unknown();
    }
  }
}
