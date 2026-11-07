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
      final checkedAt = DateTime.fromMillisecondsSinceEpoch(
        (json['checkedAtMs'] as num).toInt(),
      );
      final isCurrent = _now().difference(checkedAt) < kNoLyricsRetryAfter;
      if (lyrics is Map<String, dynamic>) {
        final found = Lyrics.fromJson(lyrics);
        // Plain text is worth another look later: timed lyrics may have appeared.
        return LyricsLookup.found(
          found,
          isStale: !found.isSynced && !isCurrent,
        );
      }
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
  const LyricsLookup.found(Lyrics this.lyrics, {this.isStale = false})
    : isCertain = true;
  const LyricsLookup.none() : lyrics = null, isCertain = true, isStale = false;
  const LyricsLookup.unknown()
    : lyrics = null,
      isCertain = false,
      isStale = false;

  final Lyrics? lyrics;
  final bool isCertain;

  /// Saved plain lyrics old enough that timed ones may exist by now.
  final bool isStale;
}

/// Finds lyrics: saved copy first, then the server (embedded or .lrc files),
/// then the public LRCLIB database.
class LyricsService {
  LyricsService({http.Client? httpClient, this.store})
    : _http = httpClient ?? http.Client();

  final http.Client _http;
  final LyricsStore? store;
  final Map<String, Future<Lyrics?>> _cache = {};
  final Map<String, Lyrics> _found = {};

  Future<Lyrics?> forSong(SubsonicClient client, Song song) =>
      _cache.putIfAbsent(song.id, () => _resolveAndRemember(client, song));

  /// Lyrics already found this session, without waiting: the player opens straight
  /// into its lyrics layout instead of switching to it a moment later.
  Lyrics? peek(String songId) => _found[songId];

  Future<Lyrics?> _resolveAndRemember(SubsonicClient client, Song song) async {
    final lyrics = await _resolve(client, song);
    if (lyrics != null) _found[song.id] = lyrics;
    return lyrics;
  }

  Future<Lyrics?> _resolve(SubsonicClient client, Song song) async {
    final saved = await store?.read(song.id);
    if (saved != null && !saved.isStale) return saved.lyrics;
    final lookup = await _find(client, song);
    final upgrade = lookup.lyrics;
    if (saved != null && (upgrade == null || !upgrade.isSynced)) {
      // Nothing better turned up: keep what was saved and look again later.
      await store?.write(song.id, saved);
      return saved.lyrics;
    }
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

  /// Asks LRCLIB for the best copy: exact match first, then looser spellings
  /// (no "feat." or "Remastered" suffix, first artist only), then a search.
  /// Timed lyrics always win over plain text found along the way.
  Future<LyricsLookup> _findPublic(Song song) async {
    var isCertain = true;
    Lyrics? plain;
    for (final attempt in _publicAttempts(song)) {
      final result = await attempt();
      if (!result.isCertain) isCertain = false;
      final lyrics = result.lyrics;
      if (lyrics == null) continue;
      if (lyrics.isSynced) return result;
      plain ??= lyrics;
    }
    if (plain != null) return LyricsLookup.found(plain);
    return isCertain ? const LyricsLookup.none() : const LyricsLookup.unknown();
  }

  List<Future<LyricsLookup> Function()> _publicAttempts(Song song) {
    final title = cleanLyricsTitle(song.title);
    final artist = primaryLyricsArtist(song.artist);
    final isSameQuery = title == song.title && artist == song.artist;
    return [
      () => _get(song.artist, song.title, song.durationSeconds),
      if (!isSameQuery) () => _get(artist, title, song.durationSeconds),
      () => _search('$artist $title', song.durationSeconds),
      if (title != song.title) () => _search(title, song.durationSeconds),
    ];
  }

  Future<LyricsLookup> _get(String artist, String title, int seconds) async {
    final uri = Uri.https('lrclib.net', '/api/get', {
      'artist_name': artist,
      'track_name': title,
      if (seconds > 0) 'duration': '$seconds',
    });
    return _request(uri, (body) {
      if (body is! Map<String, dynamic>) return null;
      return _lyricsFromEntry(body);
    });
  }

  Future<LyricsLookup> _search(String query, int seconds) async {
    final uri = Uri.https('lrclib.net', '/api/search', {'q': query});
    return _request(uri, (body) {
      if (body is! List) return null;
      final entries = body.whereType<Map<String, dynamic>>().where(
        (e) => _isCloseInLength(e['duration'], seconds),
      );
      Lyrics? plain;
      final ranked = entries.toList()
        ..sort(
          (a, b) => _lengthGap(
            a['duration'],
            seconds,
          ).compareTo(_lengthGap(b['duration'], seconds)),
        );
      for (final entry in ranked) {
        final lyrics = _lyricsFromEntry(entry);
        if (lyrics == null) continue;
        if (lyrics.isSynced) return lyrics;
        plain ??= lyrics;
      }
      return plain;
    });
  }

  Future<LyricsLookup> _request(
    Uri uri,
    Lyrics? Function(Object? body) pick,
  ) async {
    try {
      final response = await _http
          .get(uri, headers: {'User-Agent': 'Yomi'})
          .timeout(_lookupTimeout);
      if (response.statusCode == 404) return const LyricsLookup.none();
      if (response.statusCode != 200) return const LyricsLookup.unknown();
      final lyrics = pick(jsonDecode(utf8.decode(response.bodyBytes)));
      return lyrics == null
          ? const LyricsLookup.none()
          : LyricsLookup.found(lyrics);
    } on Object catch (error) {
      debugPrint('Public lyrics lookup failed: $error');
      return const LyricsLookup.unknown();
    }
  }

  static Lyrics? _lyricsFromEntry(Map<String, dynamic> json) {
    final synced = json['syncedLyrics'];
    if (synced is String && synced.trim().isNotEmpty) {
      final parsed = Lyrics.parseLrc(synced);
      if (parsed.isSynced) return parsed;
    }
    final plain = json['plainLyrics'];
    if (plain is String && plain.trim().isNotEmpty) {
      return Lyrics.parsePlain(plain);
    }
    return null;
  }

  /// A copy of a different length is a different recording (live, remix).
  static const int _maxLengthGapSeconds = 6;

  static num _lengthGap(Object? duration, int seconds) =>
      duration is num && seconds > 0 ? (duration - seconds).abs() : 0;

  static bool _isCloseInLength(Object? duration, int seconds) =>
      seconds <= 0 ||
      duration is! num ||
      _lengthGap(duration, seconds) <= _maxLengthGapSeconds;
}

final RegExp _bracketed = RegExp(r'\s*[\(\[][^\)\]]*[\)\]]');
final RegExp _versionSuffix = RegExp(
  r'\s+-\s+(?:\d{4}\s+)?(?:remaster(?:ed)?|remix|live|single|radio|mono|stereo|deluxe|bonus|feat\.?|ft\.?)\b.*$',
  caseSensitive: false,
);
final RegExp _featuring = RegExp(
  r'\s+(?:feat\.?|ft\.?|featuring|with)\s+.*$',
  caseSensitive: false,
);

/// Strips "(feat. X)", "[Deluxe]" and "- 2011 Remaster" so lookups match the
/// spelling lyric databases use.
String cleanLyricsTitle(String title) {
  final cleaned = title
      .replaceAll(_bracketed, '')
      .replaceAll(_versionSuffix, '')
      .replaceAll(_featuring, '')
      .trim();
  return cleaned.isEmpty ? title.trim() : cleaned;
}

/// The lead artist of "A, B", "A & B", "A feat. B" or "A; B".
String primaryLyricsArtist(String artist) {
  final lead = artist
      .split(
        RegExp(
          r'\s*(?:,|;|&|/|\bfeat\.?\b|\bft\.?\b|\bx\b)\s*',
          caseSensitive: false,
        ),
      )
      .first
      .trim();
  return lead.isEmpty ? artist.trim() : lead;
}
