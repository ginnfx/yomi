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

/// At least this share of a personal shelf is songs not played recently, so suggestions
/// keep moving instead of repeating favourites.
const double kFreshShare = 0.5;

/// No shelf shows more than this many songs from one artist or one album.
const int kMaxPerArtist = 2;

/// The most shelves Home shows.
const int kMaxShelves = 20;

/// A song shown this many times without being played is dropped until it's played.
const int kShownLimit = 4;

/// How many artists and genres get their own shelves each day.
const int _shelvesPerFamily = 3;

/// Candidates for those shelves. Beyond the top few, taste is mostly noise.
const int _topCandidates = 10;

/// Songs played within this long are counted as "recent", not as fresh.
const Duration _recentPlay = Duration(days: 14);

/// A server play count is older and vaguer than a play on this device.
const double _serverPlayWeight = 0.2;

const Duration _rediscoverAfter = Duration(days: 30);
const double _skipPenalty = 0.5;
const double _starBonus = 1.5;

/// How much a like counts towards taste for its artist and genre, in plays.
const double _starTaste = 1;

/// Home is reshuffled at most after this many new plays, so it reacts without flickering.
const int kPlaysPerRefresh = 5;

enum ShelfKind {
  jumpBack,
  becauseYouPlayed,
  topGenre,
  rediscover,
  timeOfDay,
  recentlyAdded,
  discover,
  artistsYouLove,
  newToYou,
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
    required List<Song> pool,
    required this.recentlyAdded,
    required this.now,
    this.starred = const {},
    this.shown = const {},
    this.lessArtists = const {},
    this.lessSongs = const {},
  }) : pool = [
         for (final song in pool)
           if (!lessSongs.contains(song.id) &&
               !lessArtists.contains(song.artist))
             song,
       ],
       _random = Random(_seedFor(homeRotationKey(now, events.length))) {
    _songsById = {for (final song in this.pool) song.id: song};
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
    for (final song in this.pool) {
      if (song.playCount > 0 && !_plays.containsKey(song.id)) {
        _serverPlays[song.id] = log(1 + song.playCount) * _serverPlayWeight;
      }
    }
  }

  final List<PlayEvent> events;

  /// Songs to choose from: the library, or a sample of it.
  final List<Song> pool;
  final List<Song> recentlyAdded;
  final DateTime now;
  final Set<String> starred;

  /// How many times each song has been shown since it was last played.
  final Map<String, int> shown;

  /// What "show less like this" has ruled out.
  final Set<String> lessArtists;
  final Set<String> lessSongs;
  final Random _random;
  late final Map<String, Song> _songsById;
  final Map<String, double> _plays = {};
  final Map<String, double> _serverPlays = {};
  final Map<String, double> _skips = {};
  final Map<String, DateTime> _lastPlayed = {};

  double _decay(DateTime at) {
    final age = now.difference(at);
    return pow(0.5, age.inHours / kTasteHalfLife.inHours).toDouble();
  }

  /// How much the user seems to like a song. Skips count against it.
  double scoreOf(Song song) =>
      (_plays[song.id] ?? _serverPlays[song.id] ?? 0) -
      (_skips[song.id] ?? 0) * _skipPenalty +
      (starred.contains(song.id) ? _starBonus : 0);

  /// Total taste per artist or genre, from plays, server counts and likes.
  Map<String, double> _affinity(String? Function(Song) groupOf) {
    final totals = <String, double>{};
    void add(Song? song, double weight) {
      if (song == null) return;
      final group = groupOf(song);
      if (group != null) totals[group] = (totals[group] ?? 0) + weight;
    }

    _plays.forEach((id, weight) => add(_songsById[id], weight));
    _serverPlays.forEach((id, weight) => add(_songsById[id], weight));
    for (final id in starred) {
      add(_songsById[id], _starTaste);
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

  bool _isWornOut(Song song) => (shown[song.id] ?? 0) >= kShownLimit;

  bool _playedRecently(Song song) {
    final last = _lastPlayed[song.id];
    return last != null && now.difference(last) < _recentPlay;
  }

  /// Keeps songs in order, leaving out any that would put too many from one artist or
  /// album on a shelf, up to [limit].
  List<Song> _varied(Iterable<Song> songs, {int limit = kShelfSize}) {
    final artists = <String, int>{};
    final albums = <String, int>{};
    final picked = <Song>[];
    final leftOut = <Song>[];
    for (final song in songs) {
      if (picked.length >= limit) break;
      final artist = song.artist;
      final album = song.albumId ?? song.album;
      if ((artists[artist] ?? 0) >= kMaxPerArtist ||
          (albums[album] ?? 0) >= kMaxPerArtist) {
        leftOut.add(song);
        continue;
      }
      artists[artist] = (artists[artist] ?? 0) + 1;
      albums[album] = (albums[album] ?? 0) + 1;
      picked.add(song);
    }
    // A small library may not have the variety. A repetitive shelf beats an empty Home.
    if (picked.length < kMinShelfSongs) {
      picked.addAll(leftOut.take(limit - picked.length));
    }
    return picked;
  }

  /// Ranks [songs] by taste with some variation, with at least half the shelf from songs
  /// not played recently.
  List<Song> _pick(Iterable<Song> songs) {
    final candidates = songs
        .where((song) => scoreOf(song) >= 0 && !_isWornOut(song))
        .toList();
    final jitter = {
      for (final song in candidates) song.id: 0.7 + _random.nextDouble() * 0.6,
    };
    double rank(Song song) => (scoreOf(song) + 0.01) * jitter[song.id]!;
    final familiar = [
      for (final song in candidates)
        if (_playedRecently(song)) song,
    ]..sort((a, b) => rank(b).compareTo(rank(a)));
    final fresh = [
      for (final song in candidates)
        if (!_playedRecently(song)) song,
    ]..shuffle(_random);
    fresh.sort(
      (a, b) =>
          scoreOf(b) > 0 == scoreOf(a) > 0 ? 0 : (scoreOf(b) > 0 ? 1 : -1),
    );
    final familiarSlots = (kShelfSize * (1 - kFreshShare)).floor();
    final picked = _varied([...familiar.take(familiarSlots), ...fresh]);
    return List.unmodifiable([...picked]..shuffle(_random));
  }

  /// Several favourites, chosen by weighted chance rather than always the same winner.
  List<String> _favourites(
    Map<String, double> totals, {
    int count = _shelvesPerFamily,
  }) {
    final top =
        (totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(_topCandidates)
            .where((entry) => entry.value > 0)
            .toList();
    final chosen = <String>[];
    while (chosen.length < count && top.isNotEmpty) {
      final total = top.fold<double>(0, (sum, entry) => sum + entry.value);
      var roll = _random.nextDouble() * total;
      var index = 0;
      for (; index < top.length - 1; index++) {
        roll -= top[index].value;
        if (roll <= 0) break;
      }
      chosen.add(top.removeAt(index).key);
    }
    return chosen;
  }

  HomeShelf? _jumpBack() {
    final ids = _lastPlayed.keys.toList()
      ..sort((a, b) => _lastPlayed[b]!.compareTo(_lastPlayed[a]!));
    return _shelf(
      ShelfKind.jumpBack,
      'Jump back in',
      _varied([for (final id in ids) ?_songsById[id]]),
    );
  }

  List<HomeShelf> _becauseYouPlayed(List<String> artists) => [
    for (final artist in artists)
      ?_shelf(
        ShelfKind.becauseYouPlayed,
        'Because you played $artist',
        _pick(_relatedTo(artist)),
      ),
  ];

  /// An artist's songs, and others in their genres. Others come along so a shelf can be
  /// full despite the per-artist limit, which is also what makes it a discovery shelf.
  Iterable<Song> _relatedTo(String artist) {
    final genres = pool
        .where((song) => _artistOf(song) == artist)
        .map(_genreOf)
        .whereType<String>()
        .toSet();
    return pool.where(
      (song) =>
          _artistOf(song) == artist ||
          (_genreOf(song) != null && genres.contains(_genreOf(song))),
    );
  }

  List<HomeShelf> _moreFrom(List<String> artists) => [
    for (final artist in artists) ?_shelfOfArtist(artist),
  ];

  HomeShelf? _shelfOfArtist(String artist) {
    // Albums of one artist rather than the shelf limit, as this shelf is about them.
    final songs = pool.where((song) => _artistOf(song) == artist).toList()
      ..shuffle(_random);
    final albums = <String, int>{};
    final picked = <Song>[];
    for (final song in songs) {
      final album = song.albumId ?? song.album;
      if ((albums[album] ?? 0) >= kMaxPerArtist) continue;
      albums[album] = (albums[album] ?? 0) + 1;
      picked.add(song);
    }
    final related = _varied(
      _relatedTo(artist).where((song) => _artistOf(song) != artist),
    );
    return _shelf(
      ShelfKind.artistsYouLove,
      'Around $artist',
      _varied([...picked.take(kMaxPerArtist), ...related]),
    );
  }

  List<HomeShelf> _topGenres() => [
    for (final genre in _favourites(_affinity(_genreOf)))
      ?_shelf(
        ShelfKind.topGenre,
        'More $genre',
        _pick(pool.where((song) => _genreOf(song) == genre)),
      ),
  ];

  HomeShelf? _rediscover() {
    final cutoff = now.subtract(_rediscoverAfter);
    final songs = [
      for (final entry in _lastPlayed.entries)
        if (entry.value.isBefore(cutoff)) ?_songsById[entry.key],
    ]..shuffle(_random);
    return _shelf(ShelfKind.rediscover, 'Rediscover', _varied(songs));
  }

  /// What you usually play at this hour, plus more from those artists and genres.
  HomeShelf? _timeOfDay() {
    final usual = <String>{
      for (final event in events)
        if (event.kind == PlayKind.completed && _sameTimeOfDay(event.at, now))
          event.songId,
    };
    final habit = [for (final id in usual) ?_songsById[id]];
    if (habit.isEmpty) return null;
    final others = <String>{
      for (final event in events)
        if (event.kind == PlayKind.completed && !usual.contains(event.songId))
          event.songId,
    };
    final artists = habit.map(_artistOf).whereType<String>().toSet();
    final genres = habit.map(_genreOf).whereType<String>().toSet();
    final similar = pool.where(
      (song) =>
          !usual.contains(song.id) &&
          !others.contains(song.id) &&
          (artists.contains(_artistOf(song)) ||
              genres.contains(_genreOf(song))),
    );
    final habitSlots = (kShelfSize * (1 - kFreshShare)).floor();
    final mixed = _varied([
      ...(habit..shuffle(_random)).take(habitSlots),
      ...similar.toList()..shuffle(_random),
    ]);
    return _shelf(
      ShelfKind.timeOfDay,
      timeOfDayTitle(now),
      List.unmodifiable(mixed..shuffle(_random)),
    );
  }

  HomeShelf? _discover() {
    final unplayed =
        pool
            .where(
              (s) =>
                  !_plays.containsKey(s.id) &&
                  !_serverPlays.containsKey(s.id) &&
                  !_isWornOut(s),
            )
            .toList()
          ..shuffle(_random);
    return _shelf(ShelfKind.discover, 'Something different', _varied(unplayed));
  }

  /// One song each from artists you've never played.
  HomeShelf? _newToYou() {
    final played = _affinity(_artistOf).keys.toSet();
    final byArtist = <String, List<Song>>{};
    for (final song in pool) {
      final artist = _artistOf(song);
      if (artist == null || played.contains(artist) || _isWornOut(song)) {
        continue;
      }
      (byArtist[artist] ??= []).add(song);
    }
    final artists = byArtist.keys.toList()..shuffle(_random);
    return _shelf(ShelfKind.newToYou, 'New to you', [
      for (final artist in artists.take(kShelfSize))
        byArtist[artist]![_random.nextInt(byArtist[artist]!.length)],
    ]);
  }

  /// Takes a little from many recent albums, newest albums more often, so one big upload
  /// can't fill the shelf and each day shows something else.
  HomeShelf? _recentlyAddedShelf() {
    final byAlbum = <String, List<Song>>{};
    for (final song in recentlyAdded) {
      if (lessSongs.contains(song.id) || lessArtists.contains(song.artist)) {
        continue;
      }
      (byAlbum[song.albumId ?? song.album] ??= []).add(song);
    }
    final albums = byAlbum.keys.toList();
    final order = <String>[
      ...albums.take(_shelvesPerFamily),
      ...albums.skip(_shelvesPerFamily).toList()..shuffle(_random),
    ];
    final firstFromEach = <Song>[];
    final theRest = <Song>[];
    for (final album in order) {
      final tracks = byAlbum[album]!..shuffle(_random);
      firstFromEach.addAll(tracks.take(kMaxPerArtist));
      theRest.addAll(tracks.skip(kMaxPerArtist));
    }
    return _shelf(
      ShelfKind.recentlyAdded,
      'Recently added',
      _varied([...firstFromEach, ...theRest]),
    );
  }

  HomeShelf? _shelf(ShelfKind kind, String title, List<Song> songs) =>
      songs.length < kMinShelfSongs ? null : HomeShelf(kind, title, songs);

  /// The shelves to show. [Jump back in] always leads; the rest rotate daily unless
  /// [keepOrder] holds the user's own arrangement of each kind of shelf.
  List<HomeShelf> build({List<ShelfKind>? keepOrder}) {
    final recent = _recentlyAddedShelf();
    final hasTaste = _affinity(_artistOf).isNotEmpty;
    final completedPlays =
        events.where((event) => event.kind == PlayKind.completed).length +
        _serverPlays.length;
    if (completedPlays < kMinPlaysForPersonal || !hasTaste) {
      return List.unmodifiable(
        [_jumpBack(), recent, _discover(), _newToYou()].whereType<HomeShelf>(),
      );
    }
    final favourites = _favourites(
      _affinity(_artistOf),
      count: _shelvesPerFamily * 2,
    );
    final rotating = [
      ..._becauseYouPlayed(favourites.take(_shelvesPerFamily).toList()),
      ..._moreFrom(favourites.skip(_shelvesPerFamily).toList()),
      ..._topGenres(),
      _rediscover(),
      _timeOfDay(),
      recent,
      _discover(),
      _newToYou(),
    ].whereType<HomeShelf>().toList()..shuffle(_random);
    final shelves = [?_jumpBack(), ...rotating].take(kMaxShelves).toList();
    if (keepOrder == null) return List.unmodifiable(shelves);
    int place(ShelfKind kind) {
      final index = keepOrder.indexOf(kind);
      return index < 0 ? keepOrder.length : index;
    }

    final indexed = shelves.indexed.toList()
      ..sort((a, b) {
        final byKind = place(a.$2.kind).compareTo(place(b.$2.kind));
        return byKind != 0 ? byKind : a.$1.compareTo(b.$1);
      });
    return List.unmodifiable([for (final (_, shelf) in indexed) shelf]);
  }
}
