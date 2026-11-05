import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../search_index.dart';
import 'spotify_export.dart';

/// Lengths this close are the same recording.
const int _sameLengthSeconds = 2;
const int _maxTypoDistance = 2;
const int _minLengthForTypos = 6;
const int _maxAlternatives = 5;

enum MatchStatus { matched, check, missing }

/// What was found for a track, and how sure that is.
@immutable
class TrackMatch {
  const TrackMatch(this.status, {this.song, this.alternatives = const []});

  final MatchStatus status;
  final Song? song;

  /// Other songs that might be it, to choose from.
  final List<Song> alternatives;
}

/// Words saying a recording is a different version. A live take or a remix isn't the song
/// someone asked for, so these have to agree on both sides.
const Set<String> _versionWords = {
  'live',
  'remix',
  'acoustic',
  'instrumental',
  'karaoke',
  'demo',
  'cover',
  'edit',
};

/// Words that describe an edition rather than a different recording, and can be dropped.
final RegExp _editionPart = RegExp(
  r'\s*[-–(\[]\s*('
  r'feat\.?|ft\.?|featuring|with\s|'
  r'(\d{4}\s+)?(digital\s+)?remaster(ed)?|(\d{4}\s+)?mix\b|'
  r'radio\s+edit|album\s+version|single\s+version|original\s+mix|'
  r'mono|stereo|bonus\s+track|deluxe'
  r')[^)\]]*[)\]]?',
  caseSensitive: false,
);
final RegExp _featInName = RegExp(
  r'\s+(feat\.?|ft\.?|featuring)\s.*$',
  caseSensitive: false,
);

class _CleanTitle {
  const _CleanTitle(this.text, this.versions);

  final String text;
  final Set<String> versions;
}

_CleanTitle _cleanTitle(String title) {
  final withoutEdition = title.replaceAll(_editionPart, '');
  final words = normalizeForSearch(withoutEdition).split(' ');
  final versions = words.where(_versionWords.contains).toSet();
  // The title keeps only what comes before a version part such as "- Live in Paris".
  final beforeVersion = withoutEdition.split(RegExp(r'\s[-–]\s|[(\[]')).first;
  final base = normalizeForSearch(
    versions.isEmpty ? withoutEdition : beforeVersion,
  );
  return _CleanTitle(base.isEmpty ? normalizeForSearch(title) : base, versions);
}

/// The artists named, as Spotify lists several where a library file may hold just one.
Set<String> _artistsOf(String artist) => artist
    .replaceAll(_featInName, '')
    .split(RegExp(r',|;|&| x | and ', caseSensitive: false))
    .map(normalizeForSearch)
    .where((name) => name.isNotEmpty)
    .toSet();

/// Finds library songs for tracks from elsewhere.
class TrackMatcher {
  TrackMatcher(List<Song> library) {
    for (final song in library) {
      final clean = _cleanTitle(song.title);
      final entry = _Entry(song, clean.versions, _artistsOf(song.artist));
      (_byTitle[clean.text] ??= []).add(entry);
    }
    _titles = _byTitle.keys.toList(growable: false);
  }

  final Map<String, List<_Entry>> _byTitle = {};
  late final List<String> _titles;

  TrackMatch match(ExportTrack track) {
    final clean = _cleanTitle(track.title);
    final artists = _artistsOf(track.artist);
    final exact = _sameVersion(_byTitle[clean.text], clean);
    final sameArtist = [
      for (final entry in exact)
        if (entry.artists.any(artists.contains)) entry,
    ];
    if (sameArtist.isNotEmpty) return _fromSameArtist(sameArtist, track);
    if (exact.isNotEmpty) {
      return TrackMatch(
        MatchStatus.check,
        song: exact.first.song,
        alternatives: _songs(exact),
      );
    }
    return _closeSpelling(clean, artists);
  }

  List<_Entry> _sameVersion(List<_Entry>? entries, _CleanTitle clean) => [
    for (final entry in entries ?? const <_Entry>[])
      if (setEquals(entry.versions, clean.versions)) entry,
  ];

  TrackMatch _fromSameArtist(List<_Entry> entries, ExportTrack track) {
    final wanted = track.durationSeconds;
    if (wanted == null) {
      return TrackMatch(
        MatchStatus.matched,
        song: entries.first.song,
        alternatives: _songs(entries),
      );
    }
    final closest = [...entries]
      ..sort(
        (a, b) => (a.song.durationSeconds - wanted).abs().compareTo(
          (b.song.durationSeconds - wanted).abs(),
        ),
      );
    final best = closest.first.song;
    final isSameLength =
        (best.durationSeconds - wanted).abs() <= _sameLengthSeconds;
    return TrackMatch(
      isSameLength ? MatchStatus.matched : MatchStatus.check,
      song: best,
      alternatives: _songs(closest),
    );
  }

  /// A title spelled slightly differently by the same artist is worth a look, never a
  /// sure thing, as "Stay" and "Stray" are different songs.
  TrackMatch _closeSpelling(_CleanTitle clean, Set<String> artists) {
    if (clean.text.length < _minLengthForTypos) {
      return const TrackMatch(MatchStatus.missing);
    }
    final close = <_Entry>[];
    for (final title in _titles) {
      if ((title.length - clean.text.length).abs() > _maxTypoDistance) continue;
      if (_distance(title, clean.text) > _maxTypoDistance) continue;
      for (final entry in _sameVersion(_byTitle[title], clean)) {
        if (entry.artists.any(artists.contains)) close.add(entry);
      }
    }
    if (close.isEmpty) return const TrackMatch(MatchStatus.missing);
    return TrackMatch(
      MatchStatus.check,
      song: close.first.song,
      alternatives: _songs(close),
    );
  }

  List<Song> _songs(List<_Entry> entries) => [
    for (final entry in entries.take(_maxAlternatives)) entry.song,
  ];

  static int _distance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, i);
      var smallest = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        current[j] = min(
          min(previous[j] + 1, current[j - 1] + 1),
          previous[j - 1] + cost,
        );
        smallest = min(smallest, current[j]);
      }
      if (smallest > _maxTypoDistance) return smallest;
      previous = current;
    }
    return previous[b.length];
  }
}

@immutable
class _Entry {
  const _Entry(this.song, this.versions, this.artists);

  final Song song;
  final Set<String> versions;
  final Set<String> artists;
}
