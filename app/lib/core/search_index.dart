import 'dart:math';

import 'package:diacritic/diacritic.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';

const int _maxSongs = 200;
const int _maxGroup = 10;
const int _maxArtists = 5;

/// How well a typed word matched a word in the library, best first.
const double _exactScore = 1;
const double _prefixScore = 0.8;
const double _insideScore = 0.5;
const double _typoScore = 0.4;

/// Where a match was found. A title match means more than an album match.
const double _titleWeight = 1;
const double _artistWeight = 0.75;
const double _albumWeight = 0.5;

const double _fullTitleBonus = 2;
const double _playsBonus = 0.05;

/// Words this short need an exact start: one typo in them could be almost anything.
const int _minLengthForTypos = 4;
const int _lengthForTwoTypos = 8;

/// Words shorter than this are only matched from their start, so "lo" finds "love" and
/// not "hello".
const int _minLengthInsideWord = 3;

final RegExp _notWordCharacters = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Scripts written without spaces, where a search can start anywhere in a word.
final RegExp _unspacedScript = RegExp(r'[぀-ヿ㐀-鿿가-힯]');

/// Lower case, no accents, and punctuation becoming spaces.
String normalizeForSearch(String text) =>
    removeDiacritics(text.toLowerCase())
        .replaceAll(_notWordCharacters, ' ')
        .trim();

List<String> _wordsOf(String text) {
  final normalized = normalizeForSearch(text);
  return normalized.isEmpty ? const [] : normalized.split(' ');
}

/// The best single result to show first.
sealed class TopResult {
  const TopResult();
}

class SongMatch extends TopResult {
  const SongMatch(this.song);

  final Song song;
}

class ArtistMatch extends TopResult {
  const ArtistMatch(this.artist);

  final ArtistResult artist;
}

/// An artist found in the library's songs.
@immutable
class ArtistResult {
  const ArtistResult({
    required this.name,
    required this.songCount,
    this.coverArtId,
  });

  final String name;
  final int songCount;
  final String? coverArtId;
}

/// An album found in the library's songs.
@immutable
class AlbumResult {
  const AlbumResult({
    required this.id,
    required this.name,
    required this.artist,
    this.coverArtId,
  });

  final String id;
  final String name;
  final String artist;
  final String? coverArtId;
}

/// Search results grouped for display.
@immutable
class IndexedResults {
  const IndexedResults({
    this.topResult,
    this.songs = const [],
    this.artists = const [],
    this.albums = const [],
  });

  final TopResult? topResult;
  final List<Song> songs;
  final List<ArtistResult> artists;
  final List<AlbumResult> albums;

  bool get isEmpty => songs.isEmpty && artists.isEmpty && albums.isEmpty;
}

/// Finds songs by what you meant rather than what you typed exactly. Works on the saved
/// library, so it's instant and needs no connection.
class SearchIndex {
  SearchIndex(this._songs) {
    for (var i = 0; i < _songs.length; i++) {
      final song = _songs[i];
      _addWords(song.title, i, _Field.title);
      _addWords(song.artist, i, _Field.artist);
      _addWords(song.album, i, _Field.album);
      _titles.add(normalizeForSearch(song.title));
      _artists.add(normalizeForSearch(song.artist));
    }
    _vocabulary = _postings.keys.toList(growable: false);
  }

  final List<Song> _songs;
  final List<String> _titles = [];
  final List<String> _artists = [];

  /// Each word points to the songs and fields containing it, so a search looks at each
  /// distinct word once rather than at every song.
  final Map<String, List<_Posting>> _postings = {};
  late final List<String> _vocabulary;

  void _addWords(String text, int song, _Field field) {
    for (final word in _wordsOf(text).toSet()) {
      (_postings[word] ??= []).add(_Posting(song, field));
    }
  }

  IndexedResults search(String query) {
    final words = _wordsOf(query).toSet().toList();
    if (words.isEmpty) return const IndexedResults();
    var scores = _scoresFor(words.first);
    for (final word in words.skip(1)) {
      final next = _scoresFor(word);
      scores = {
        for (final entry in scores.entries)
          if (next.containsKey(entry.key))
            entry.key: entry.value.plus(next[entry.key]!),
      };
      if (scores.isEmpty) return const IndexedResults();
    }
    final normalized = words.join(' ');
    double total(int song) {
      final isFullTitle = _titles[song] == normalized;
      return scores[song]!.total +
          (isFullTitle ? _fullTitleBonus : 0) +
          log(1 + _songs[song].playCount) * _playsBonus;
    }

    final ranked = scores.keys.toList()
      ..sort((a, b) => total(b).compareTo(total(a)));
    final songs = [for (final i in ranked.take(_maxSongs)) _songs[i]];
    final artists = _artistsFrom(scores, normalized);
    final albums = _albumsFrom(scores);
    return IndexedResults(
      topResult: _topResult(ranked, normalized, artists),
      songs: List.unmodifiable(songs),
      artists: List.unmodifiable(artists),
      albums: List.unmodifiable(albums),
    );
  }

  TopResult? _topResult(
    List<int> ranked,
    String normalized,
    List<ArtistResult> artists,
  ) {
    if (artists.isNotEmpty &&
        normalizeForSearch(artists.first.name) == normalized) {
      return ArtistMatch(artists.first);
    }
    return ranked.isEmpty ? null : SongMatch(_songs[ranked.first]);
  }

  /// Individual artists whose own name matched what was typed. Credits like
  /// "A, B & C" are split, so a featured artist is one result, not one per credit.
  List<ArtistResult> _artistsFrom(Map<int, _Score> scores, String normalized) {
    final typed = normalized.split(' ');
    final found = <String, _ArtistGroup>{};
    for (final entry in scores.entries) {
      if (entry.value.artist <= 0) continue;
      final song = _songs[entry.key];
      for (final name in splitArtistCredit(song.artist)) {
        if (!_nameMatches(name, typed)) continue;
        final group = found[artistKey(name)] ??= _ArtistGroup(name);
        group.songs.add(entry.key);
      }
    }
    final groups = found.values.toList()
      ..sort((a, b) {
        final aExact = artistKey(a.name) == artistKey(normalized);
        final bExact = artistKey(b.name) == artistKey(normalized);
        if (aExact != bExact) return aExact ? -1 : 1;
        return b.songs.length.compareTo(a.songs.length);
      });
    return [
      for (final group in groups.take(_maxArtists))
        ArtistResult(
          name: group.name,
          songCount: group.songs.length,
          coverArtId: _songs[group.songs.first].coverArtId,
        ),
    ];
  }

  /// Whether every typed word is found in a single artist's name.
  static bool _nameMatches(String name, List<String> typed) {
    final words = _wordsOf(artistKey(name));
    return typed.every(
      (word) => words.any((candidate) => _matchQuality(word, candidate) > 0),
    );
  }

  /// Albums with a song whose album name matched what was typed.
  List<AlbumResult> _albumsFrom(Map<int, _Score> scores) {
    final found = <String, Song>{};
    for (final entry in scores.entries) {
      if (entry.value.album <= 0) continue;
      final song = _songs[entry.key];
      final id = song.albumId;
      if (id != null) found.putIfAbsent(id, () => song);
    }
    return [
      for (final entry in found.entries.take(_maxGroup))
        AlbumResult(
          id: entry.key,
          name: entry.value.album,
          artist: entry.value.artist,
          coverArtId: entry.value.coverArtId,
        ),
    ];
  }

  /// Scores every song containing something like [word].
  Map<int, _Score> _scoresFor(String word) {
    final scores = <int, _Score>{};
    for (final candidate in _vocabulary) {
      final quality = _matchQuality(word, candidate);
      if (quality <= 0) continue;
      for (final posting in _postings[candidate]!) {
        final current = scores[posting.song] ?? const _Score();
        scores[posting.song] = current.withBest(posting.field, quality);
      }
    }
    return scores;
  }

  static double _matchQuality(String typed, String word) {
    if (word == typed) return _exactScore;
    if (word.startsWith(typed)) {
      // A closer length is a better match: "love" prefers "lover" to "lovesickness".
      return _prefixScore *
          (1 - (word.length - typed.length) / (word.length * 4));
    }
    final isUnspaced = _unspacedScript.hasMatch(typed);
    if ((typed.length >= _minLengthInsideWord || isUnspaced) &&
        word.contains(typed)) {
      return _insideScore;
    }
    if (isUnspaced || typed.length < _minLengthForTypos) return 0;
    final allowed = typed.length >= _lengthForTwoTypos ? 2 : 1;
    if ((word.length - typed.length).abs() > allowed) return 0;
    return _editDistance(typed, word, allowed) <= allowed ? _typoScore : 0;
  }

  /// Damerau-Levenshtein, giving up once it passes [limit].
  static int _editDistance(String a, String b, int limit) {
    var beforePrevious = List<int>.filled(b.length + 1, 0);
    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      current[0] = i;
      var smallest = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var value = min(
          min(previous[j] + 1, current[j - 1] + 1),
          previous[j - 1] + cost,
        );
        if (i > 1 &&
            j > 1 &&
            a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
            a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
          value = min(value, beforePrevious[j - 2] + 1);
        }
        current[j] = value;
        smallest = min(smallest, value);
      }
      if (smallest > limit) return limit + 1;
      final spare = beforePrevious;
      beforePrevious = previous;
      previous = current;
      current = spare;
    }
    return previous[b.length];
  }
}

class _ArtistGroup {
  _ArtistGroup(this.name);

  final String name;
  final List<int> songs = [];
}

final RegExp _creditSeparator = RegExp(
  r'\s*(?:,|;|&|＆|、|/|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\band\b|\bx\b)\s*',
  caseSensitive: false,
);

/// The individual artists named in a credit such as "A, B & C".
List<String> splitArtistCredit(String credit) {
  final seen = <String>{};
  return [
    for (final part in credit.split(_creditSeparator))
      if (part.trim().isNotEmpty && seen.add(artistKey(part))) part.trim(),
  ];
}

/// Same artist however it is cased, accented or written in full-width letters.
String artistKey(String name) {
  final folded = String.fromCharCodes([
    for (final unit in name.runes)
      unit >= 0xFF01 && unit <= 0xFF5E ? unit - 0xFEE0 : unit,
  ]);
  return normalizeForSearch(folded);
}

enum _Field { title, artist, album }

@immutable
class _Posting {
  const _Posting(this.song, this.field);

  final int song;
  final _Field field;
}

/// The best match found in each field of a song.
@immutable
class _Score {
  const _Score({this.title = 0, this.artist = 0, this.album = 0});

  final double title;
  final double artist;
  final double album;

  double get total => max(
    max(title * _titleWeight, artist * _artistWeight),
    album * _albumWeight,
  );

  _Score withBest(_Field field, double quality) => switch (field) {
    _Field.title => _Score(
      title: max(title, quality),
      artist: artist,
      album: album,
    ),
    _Field.artist => _Score(
      title: title,
      artist: max(artist, quality),
      album: album,
    ),
    _Field.album => _Score(
      title: title,
      artist: artist,
      album: max(album, quality),
    ),
  };

  /// Combines the matches for two typed words.
  _Score plus(_Score other) => _Score(
    title: title + other.title,
    artist: artist + other.artist,
    album: album + other.album,
  );
}
