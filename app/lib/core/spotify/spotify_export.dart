import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

/// Spotify itself counts a play from this point on.
const int _minMsPlayed = 30000;
const int _maxTopItems = 100;
const int _hoursInDay = 24;

/// Far bigger than any real history file. A zip can claim, and unpack to, almost any size,
/// so anything beyond this isn't opened.
const int maxExportEntryBytes = 256 << 20;

/// One listen from a Spotify export, with nothing else from the record kept. Exports also
/// hold things like IP addresses, which never leave the parser.
@immutable
class HistoryRow {
  const HistoryRow({
    required this.at,
    required this.track,
    required this.artist,
    required this.msPlayed,
    this.album,
  });

  final DateTime at;
  final String track;
  final String artist;
  final String? album;
  final int msPlayed;

  /// Identifies this listen across files, so overlapping exports add nothing twice.
  String get key => '${at.millisecondsSinceEpoch}|$artist|$track';

  Map<String, Object?> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'track': track,
    'artist': artist,
    'album': album,
    'ms': msPlayed,
  };
}

/// Reads either kind of history export. Rows that can't be read are skipped, because a
/// few odd rows shouldn't lose the rest of someone's years of listening.
List<HistoryRow> parseHistoryFile(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  final rows = <HistoryRow>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final row = _parseRow(item);
    if (row != null) rows.add(row);
  }
  return rows;
}

HistoryRow? _parseRow(Map<dynamic, dynamic> json) {
  final track = json['master_metadata_track_name'] ?? json['trackName'];
  final artist =
      json['master_metadata_album_artist_name'] ?? json['artistName'];
  final played = json['ms_played'] ?? json['msPlayed'];
  final time = json['ts'] ?? json['endTime'];
  if (track is! String ||
      artist is! String ||
      played is! num ||
      time is! String) {
    return null; // Podcasts have no track name, and land here too.
  }
  if (played < _minMsPlayed || track.isEmpty || artist.isEmpty) return null;
  final at = _parseTime(time);
  if (at == null) return null;
  final album = json['master_metadata_album_album_name'];
  return HistoryRow(
    at: at,
    track: track,
    artist: artist,
    album: album is String ? album : null,
    msPlayed: played.toInt(),
  );
}

/// Times are UTC in both formats, though only the extended one says so.
DateTime? _parseTime(String text) {
  final normalized = text.contains('T')
      ? text
      : '${text.replaceFirst(' ', 'T')}:00Z';
  return DateTime.tryParse(normalized)?.toUtc();
}

/// A track's total within some period.
@immutable
class TrackTotal {
  const TrackTotal({
    required this.track,
    required this.artist,
    required this.plays,
    required this.ms,
  });

  factory TrackTotal.fromJson(Map<String, dynamic> json) => TrackTotal(
    track: json['t'] as String,
    artist: json['a'] as String,
    plays: (json['p'] as num).toInt(),
    ms: (json['m'] as num).toInt(),
  );

  final String track;
  final String artist;
  final int plays;
  final int ms;

  TrackTotal adding(int ms) => TrackTotal(
    track: track,
    artist: artist,
    plays: plays + 1,
    ms: this.ms + ms,
  );

  Map<String, Object?> toJson() => {
    't': track,
    'a': artist,
    'p': plays,
    'm': ms,
  };
}

@immutable
class ArtistTotal {
  const ArtistTotal({
    required this.name,
    required this.plays,
    required this.ms,
  });

  final String name;
  final int plays;
  final int ms;
}

/// Totals from Spotify, small enough to keep on the phone server: by month rather than
/// by listen, plus just enough to avoid counting the same listen twice.
@immutable
class ImportedHistory {
  const ImportedHistory({
    required this.months,
    required this.hours,
    required this.seen,
  });

  factory ImportedHistory.empty() =>
      const ImportedHistory(months: {}, hours: {}, seen: {});

  factory ImportedHistory.fromJson(
    Map<String, dynamic> json,
  ) => ImportedHistory(
    months: {
      for (final month
          in ((json['months'] as Map<String, dynamic>?) ?? const {}).entries)
        month.key: {
          for (final row
              in (month.value as List<dynamic>).cast<Map<String, dynamic>>())
            _trackKey(row['a'] as String, row['t'] as String):
                TrackTotal.fromJson(row),
        },
    },
    hours: {
      for (final year
          in ((json['hours'] as Map<String, dynamic>?) ?? const {}).entries)
        int.parse(year.key): (year.value as List<dynamic>).cast<int>(),
    },
    seen: ((json['seen'] as List<dynamic>?) ?? const []).cast<int>().toSet(),
  );

  /// Totals by "YYYY-MM", then by track.
  final Map<String, Map<String, TrackTotal>> months;

  /// Listens by hour of the day, per year.
  final Map<int, List<int>> hours;

  /// Hashes of listens already counted.
  final Set<int> seen;

  bool get isEmpty => months.isEmpty;

  static String _trackKey(String artist, String track) => '$artist\u0000$track';

  /// A copy including [rows], ignoring any listen already counted.
  ImportedHistory adding(Iterable<HistoryRow> rows) {
    final nextMonths = {
      for (final month in months.entries) month.key: {...month.value},
    };
    final nextHours = {
      for (final year in hours.entries) year.key: [...year.value],
    };
    final nextSeen = {...seen};
    for (final row in rows) {
      if (!nextSeen.add(_stableHash(row.key))) continue;
      final month = '${row.at.year}-${row.at.month.toString().padLeft(2, '0')}';
      final tracks = nextMonths[month] ??= {};
      final key = _trackKey(row.artist, row.track);
      tracks[key] =
          (tracks[key] ??
                  TrackTotal(
                    track: row.track,
                    artist: row.artist,
                    plays: 0,
                    ms: 0,
                  ))
              .adding(row.msPlayed);
      final byHour = nextHours[row.at.year] ??= List.filled(_hoursInDay, 0);
      byHour[row.at.hour]++;
    }
    return ImportedHistory(
      months: nextMonths,
      hours: nextHours,
      seen: nextSeen,
    );
  }

  /// FNV-1a. It only has to be the same on every device and run, unlike String.hashCode.
  static int _stableHash(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  int get totalMs => months.values.fold(
    0,
    (sum, tracks) => sum + tracks.values.fold(0, (inner, t) => inner + t.ms),
  );

  List<int> get years =>
      months.keys
          .map((month) => int.parse(month.substring(0, 4)))
          .toSet()
          .toList()
        ..sort();

  Iterable<TrackTotal> _inYear(int year) => months.entries
      .where((month) => month.key.startsWith('$year-'))
      .expand((month) => month.value.values);

  int playsOf(int year) =>
      _inYear(year).fold(0, (sum, track) => sum + track.plays);

  int msOf(int year) => _inYear(year).fold(0, (sum, track) => sum + track.ms);

  List<TrackTotal> topTracks(int year) {
    final merged = <String, TrackTotal>{};
    for (final track in _inYear(year)) {
      final key = _trackKey(track.artist, track.track);
      final current = merged[key];
      merged[key] = current == null
          ? track
          : TrackTotal(
              track: track.track,
              artist: track.artist,
              plays: current.plays + track.plays,
              ms: current.ms + track.ms,
            );
    }
    return (merged.values.toList()..sort((a, b) => b.plays.compareTo(a.plays)))
        .take(_maxTopItems)
        .toList();
  }

  List<ArtistTotal> topArtists(int year) {
    final plays = <String, int>{};
    final time = <String, int>{};
    for (final track in _inYear(year)) {
      plays[track.artist] = (plays[track.artist] ?? 0) + track.plays;
      time[track.artist] = (time[track.artist] ?? 0) + track.ms;
    }
    return (plays.keys
            .map(
              (name) =>
                  ArtistTotal(name: name, plays: plays[name]!, ms: time[name]!),
            )
            .toList()
          ..sort((a, b) => b.ms.compareTo(a.ms)))
        .take(_maxTopItems)
        .toList();
  }

  /// Taste from every year together, by artist. Recent years could count more, but a
  /// gentle starting point is all this is for.
  Map<String, double> get artistTaste {
    final taste = <String, double>{};
    for (final tracks in months.values) {
      for (final track in tracks.values) {
        taste[track.artist] = (taste[track.artist] ?? 0) + track.plays;
      }
    }
    return taste;
  }

  Map<String, Object?> toJson() => {
    'months': {
      for (final month in months.entries)
        month.key: [for (final track in month.value.values) track.toJson()],
    },
    'hours': {for (final year in hours.entries) '${year.key}': year.value},
    'seen': seen.toList(),
  };
}

/// A track from a Spotify playlist or library, before it's matched to anything.
@immutable
class ExportTrack {
  const ExportTrack({
    required this.title,
    required this.artist,
    this.album,
    this.durationSeconds,
  });

  final String title;
  final String artist;
  final String? album;
  final int? durationSeconds;
}

@immutable
class ExportPlaylist {
  const ExportPlaylist({required this.name, required this.tracks});

  final String name;
  final List<ExportTrack> tracks;
}

Object? _decode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// Liked songs, from YourLibrary.json.
List<ExportTrack> parseLibraryFile(String text) {
  final json = _decode(text);
  final tracks = json is Map ? json['tracks'] : null;
  if (tracks is! List) return const [];
  return [
    for (final item in tracks)
      if (item is Map && item['track'] is String && item['artist'] is String)
        ExportTrack(
          title: item['track'] as String,
          artist: item['artist'] as String,
          album: item['album'] is String ? item['album'] as String : null,
        ),
  ];
}

/// Playlists in order, from PlaylistN.json. Podcast episodes have no track and are skipped.
List<ExportPlaylist> parsePlaylistsFile(String text) {
  final json = _decode(text);
  final playlists = json is Map ? json['playlists'] : null;
  if (playlists is! List) return const [];
  final result = <ExportPlaylist>[];
  for (final playlist in playlists) {
    if (playlist is! Map || playlist['name'] is! String) continue;
    final items = playlist['items'];
    final tracks = <ExportTrack>[];
    if (items is List) {
      for (final item in items) {
        final track = item is Map ? item['track'] : null;
        if (track is Map &&
            track['trackName'] is String &&
            track['artistName'] is String) {
          tracks.add(
            ExportTrack(
              title: track['trackName'] as String,
              artist: track['artistName'] as String,
              album: track['albumName'] is String
                  ? track['albumName'] as String
                  : null,
            ),
          );
        }
      }
    }
    result.add(
      ExportPlaylist(name: playlist['name'] as String, tracks: tracks),
    );
  }
  return result;
}

/// A playlist from a CSV such as Exportify's, found by its column names.
ExportPlaylist parsePlaylistCsv(String name, String text) {
  final rows = _parseCsv(text);
  if (rows.isEmpty) return ExportPlaylist(name: name, tracks: const []);
  final header = [for (final cell in rows.first) cell.trim().toLowerCase()];
  int column(List<String> names) => header.indexWhere(names.contains);
  final title = column(['track name', 'title', 'track', 'name', 'song']);
  final artist = column(['artist name(s)', 'artist name', 'artist', 'artists']);
  final album = column(['album name', 'album']);
  final duration = column([
    'duration (ms)',
    'duration_ms',
    'track duration (ms)',
  ]);
  if (title < 0 || artist < 0)
    return ExportPlaylist(name: name, tracks: const []);
  String? cell(List<String> row, int index) =>
      index >= 0 && index < row.length && row[index].isNotEmpty
      ? row[index]
      : null;
  return ExportPlaylist(
    name: name,
    tracks: [
      for (final row in rows.skip(1))
        if (cell(row, title) != null && cell(row, artist) != null)
          ExportTrack(
            title: cell(row, title)!,
            artist: cell(row, artist)!,
            album: cell(row, album),
            durationSeconds: _secondsFrom(cell(row, duration)),
          ),
    ],
  );
}

int? _secondsFrom(String? ms) {
  final value = ms == null ? null : int.tryParse(ms);
  return value == null ? null : (value / 1000).round();
}

List<List<String>> _parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var isQuoted = false;
  void endCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void endRow() {
    endCell();
    if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
    row = [];
  }

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (isQuoted) {
      if (char == '"' && i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (char == '"') {
        isQuoted = false;
      } else {
        cell.write(char);
      }
    } else if (char == '"') {
      isQuoted = true;
    } else if (char == ',') {
      endCell();
    } else if (char == '\n') {
      endRow();
    } else if (char != '\r') {
      cell.write(char);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

/// Everything found in one or more export files.
@immutable
class SpotifyExport {
  const SpotifyExport({
    this.history = const [],
    this.likedSongs = const [],
    this.playlists = const [],
  });

  final List<HistoryRow> history;
  final List<ExportTrack> likedSongs;
  final List<ExportPlaylist> playlists;

  bool get isEmpty =>
      history.isEmpty && likedSongs.isEmpty && playlists.isEmpty;
}

/// Reads a zip or a single file, by what it's called. Any other file in an export, such
/// as account details, is never opened.
SpotifyExport readExport(String name, List<int> bytes) {
  if (name.toLowerCase().endsWith('.zip')) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object catch (error) {
      debugPrint('Could not read $name: $error');
      return const SpotifyExport();
    }
    final history = <HistoryRow>[];
    final liked = <ExportTrack>[];
    final playlists = <ExportPlaylist>[];
    for (final file in archive.files) {
      if (!file.isFile || file.size > maxExportEntryBytes) continue;
      final part = _readNamedFile(file.name, () => file.content);
      history.addAll(part.history);
      liked.addAll(part.likedSongs);
      playlists.addAll(part.playlists);
    }
    return SpotifyExport(
      history: history,
      likedSongs: liked,
      playlists: playlists,
    );
  }
  return _readNamedFile(name, () => bytes);
}

final RegExp _historyFile = RegExp(
  r'(Streaming_History_Audio|StreamingHistory_music|StreamingHistory)[^/]*\.json$',
  caseSensitive: false,
);
final RegExp _playlistFile = RegExp(
  r'Playlist[^/]*\.json$',
  caseSensitive: false,
);
final RegExp _libraryFile = RegExp(r'YourLibrary\.json$', caseSensitive: false);

SpotifyExport _readNamedFile(String name, List<int> Function() bytes) {
  String text() => utf8.decode(bytes(), allowMalformed: true);
  if (_historyFile.hasMatch(name)) {
    return SpotifyExport(history: parseHistoryFile(text()));
  }
  if (_playlistFile.hasMatch(name)) {
    return SpotifyExport(playlists: parsePlaylistsFile(text()));
  }
  if (_libraryFile.hasMatch(name)) {
    return SpotifyExport(likedSongs: parseLibraryFile(text()));
  }
  return const SpotifyExport();
}
