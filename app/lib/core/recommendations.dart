import 'dart:math';

import 'package:flutter/foundation.dart';

import 'genres.dart';
import 'listening/play_history.dart';
import 'models.dart';

const int kShelfSize = 12;
const int kMinShelfSongs = 3;

/// Below this many plays there's too little to personalise, so Home stays general.
const int kMinPlaysForPersonal = 5;

/// A play this old counts half as much.
const Duration kTasteHalfLife = Duration(days: 30);

/// Share of a personal shelf kept for songs never played, so taste can widen.
const double kDiscoveryShare = 0.2;

const Duration _rediscoverAfter = Duration(days: 30);
const double _skipPenalty = 0.5;
const double _starBonus = 1.5;

/// Home is reshuffled at most after this many new plays, so it reacts without flickering.
const int kPlaysPerRefresh = 10;

enum ShelfKind {
  jumpBack,
  becauseYouPlayed,
  topGenre,
  rediscover,
  timeOfDay,
  recentlyAdded,
  discover,
}

@immutable
class HomeShelf {
  const HomeShelf(this.kind, this.title, this.songs);

  factory HomeShelf.fromJson(Map<String, dynamic> json) => HomeShelf(
    ShelfKind.values.byName(json['kind'] as String),
    json['title'] as String,
    List.unmodifiable(
      (json['songs'] as List<dynamic>).cast<Map<String, dynamic>>().map(
        Song.fromJson,
      ),
    ),
  );

  final ShelfKind kind;
  final String title;
  final List<Song> songs;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'title': title,
    'songs': [for (final song in songs) song.toJson()],
  };
}

/// Decides when Home should change: on a new day, or after enough new plays.
String homeRotationKey(DateTime now, int playCount) =>
    '${now.year}-${now.month}-${now.day}/${playCount ~/ kPlaysPerRefresh}';

int _seedFor(String key) => key.codeUnits.fold(17, (hash, unit) {
  return (hash * 31 + unit) & 0x7fffffff;
});

String timeOfDayTitle(DateTime now) => switch (now.hour) {
  >= 5 && < 12 => 'Morning mix',
  >= 12 && < 17 => 'Afternoon mix',
  >= 17 && < 22 => 'Evening mix',
  _ => 'Late night mix',
};

bool _sameTimeOfDay(DateTime a, DateTime b) =>
    timeOfDayTitle(a) == timeOfDayTitle(b);

/// Builds Home from what's been played. Pure: same inputs, same shelves, no I/O.
class HomeBuilder {
  HomeBuilder({
    required this.events,
    required this.pool,
    required this.recentlyAdded,
    required this.now,
    this.starred = const {},
  }) : _random = Random(_seedFor(homeRotationKey(now, events.length))) {
    _songsById = {for (final song in pool) song.id: song};
    for (final event in events) {
      final weight = _decay(event.at);
      if (event.kind == PlayKind.completed) {
        _plays[event.songId] = (_plays[event.songId] ?? 0) + weight;
        final latest = _lastPlayed[event.songId];
        if (latest == null || event.at.isAfter(latest)) {
          _lastPlayed[event.songId] = event.at;
        }
      } else {
        _skips[event.songId] = (_skips[event.songId] ?? 0) + weight;
      }
    }
  }

  final List<PlayEvent> events;

  /// Songs to choose from: played songs plus a sample of the library.
  final List<Song> pool;
  final List<Song> recentlyAdded;
  final DateTime now;
  final Set<String> starred;
  final Random _random;
  late final Map<String, Song> _songsById;
  final Map<String, double> _plays = {};
  final Map<String, double> _skips = {};
  final Map<String, DateTime> _lastPlayed = {};

  double _decay(DateTime at) {
    final age = now.difference(at);
    return pow(0.5, age.inHours / kTasteHalfLife.inHours).toDouble();
  }

  /// How much the user seems to like a song. Skips count against it.
  double scoreOf(Song song) =>
      (_plays[song.id] ?? 0) -
      (_skips[song.id] ?? 0) * _skipPenalty +
      (starred.contains(song.id) ? _starBonus : 0);

  Map<String, double> _affinity(String? Function(Song) groupOf) {
    final totals = <String, double>{};
    for (final entry in _plays.entries) {
      final song = _songsById[entry.key];
      if (song == null) continue;
      final group = groupOf(song);
      if (group == null) continue;
      totals[group] = (totals[group] ?? 0) + entry.value;
    }
    return totals;
  }

  String? _genreOf(Song song) {
    final genre = song.genre;
    return genre == null || genre.trim().isEmpty ? null : canonicalGenre(genre);
  }

  String? _artistOf(Song song) {
    final artist = song.artist.trim();
    return artist.isEmpty || artist == 'Unknown artist' ? null : artist;
  }

  /// Ranks [songs] by taste, keeping a share of never-played songs for discovery.
  List<Song> _pick(Iterable<Song> songs) {
    final candidates = songs.where((song) => scoreOf(song) >= 0).toList();
    final known = [
      for (final song in candidates)
        if (_plays.containsKey(song.id)) song,
    ]..sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));
    final fresh = [
      for (final song in candidates)
        if (!_plays.containsKey(song.id)) song,
    ]..shuffle(_random);
    final freshCount = min(fresh.length, (kShelfSize * kDiscoveryShare).ceil());
    final knownCount = min(known.length, kShelfSize - freshCount);
    final filler = fresh
        .skip(freshCount)
        .take(kShelfSize - freshCount - knownCount);
    final picked = [
      ...known.take(knownCount),
      ...fresh.take(freshCount),
      ...filler,
    ]..shuffle(_random);
    return List.unmodifiable(picked);
  }

  String? _bestOf(Map<String, double> totals) {
    if (totals.isEmpty) return null;
    return totals.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  HomeShelf? _jumpBack() {
    final ids = _lastPlayed.keys.toList()
      ..sort((a, b) => _lastPlayed[b]!.compareTo(_lastPlayed[a]!));
    final songs = [for (final id in ids) ?_songsById[id]]
        .take(kShelfSize)
        .toList();
    return _shelf(ShelfKind.jumpBack, 'Jump back in', songs);
  }

  HomeShelf? _becauseYouPlayed() {
    final artist = _bestOf(_affinity(_artistOf));
    if (artist == null) return null;
    final seedSongs = pool.where((s) => _artistOf(s) == artist);
    final genres = seedSongs.map(_genreOf).whereType<String>().toSet();
    final related = pool.where(
      (song) =>
          _artistOf(song) == artist ||
          (_genreOf(song) != null && genres.contains(_genreOf(song))),
    );
    return _shelf(
      ShelfKind.becauseYouPlayed,
      'Because you played $artist',
      _pick(related),
    );
  }

  HomeShelf? _topGenre() {
    final genre = _bestOf(_affinity(_genreOf));
    if (genre == null) return null;
    return _shelf(
      ShelfKind.topGenre,
      'More $genre',
      _pick(pool.where((song) => _genreOf(song) == genre)),
    );
  }

  HomeShelf? _rediscover() {
    final cutoff = now.subtract(_rediscoverAfter);
    final songs = [
      for (final entry in _lastPlayed.entries)
        if (entry.value.isBefore(cutoff)) ?_songsById[entry.key],
    ]..shuffle(_random);
    return _shelf(
      ShelfKind.rediscover,
      'Rediscover',
      songs.take(kShelfSize).toList(),
    );
  }

  HomeShelf? _timeOfDay() {
    final usual = <String>{
      for (final event in events)
        if (event.kind == PlayKind.completed && _sameTimeOfDay(event.at, now))
          event.songId,
    };
    final fromHabit = [for (final id in usual) ?_songsById[id]];
    final mix = _pick([
      ...fromHabit,
      ...pool.where((song) => !usual.contains(song.id)),
    ]);
    return _shelf(ShelfKind.timeOfDay, timeOfDayTitle(now), mix);
  }

  HomeShelf? _discover() {
    final unplayed = pool.where((s) => !_plays.containsKey(s.id)).toList()
      ..shuffle(_random);
    return _shelf(
      ShelfKind.discover,
      'Something different',
      unplayed.take(kShelfSize).toList(),
    );
  }

  HomeShelf? _shelf(ShelfKind kind, String title, List<Song> songs) =>
      songs.length < kMinShelfSongs ? null : HomeShelf(kind, title, songs);

  /// The shelves to show. [Jump back in] always leads; the rest rotate daily unless
  /// [keepOrder] holds the user's own arrangement.
  List<HomeShelf> build({List<ShelfKind>? keepOrder}) {
    final recent = _shelf(
      ShelfKind.recentlyAdded,
      'Recently added',
      recentlyAdded.take(kShelfSize).toList(),
    );
    final completedPlays = events
        .where((event) => event.kind == PlayKind.completed)
        .length;
    if (completedPlays < kMinPlaysForPersonal) {
      return List.unmodifiable(
        [_jumpBack(), recent, _discover()].whereType<HomeShelf>(),
      );
    }
    final rotating = [
      _becauseYouPlayed(),
      _topGenre(),
      _rediscover(),
      _timeOfDay(),
      recent,
      _discover(),
    ].whereType<HomeShelf>().toList()..shuffle(_random);
    final shelves = [?_jumpBack(), ...rotating];
    if (keepOrder == null) return List.unmodifiable(shelves);
    return List.unmodifiable(
      [...shelves]..sort(
        (a, b) =>
            keepOrder.indexOf(a.kind).compareTo(keepOrder.indexOf(b.kind)),
      ),
    );
  }
}
