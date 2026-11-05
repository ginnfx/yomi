import 'dart:math';

import 'package:flutter/foundation.dart';

import 'genres.dart';
import 'listening/play_history.dart';
import 'models.dart';
import 'taste.dart';

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

/// A song shown this many times without being played is rested for [kShownRest].
const int kShownLimit = 4;

/// After this long a song rested for being shown too often comes back.
const Duration kShownRest = Duration(days: 21);

/// How many of the newest albums always have a song on the Recently added shelf.
const int _newestAlbumsKept = 3;

/// How many of the newest albums Recently added chooses from, however big they are.
const int kRecentAlbumPool = 30;

/// A limit for libraries where albums aren't much use, such as all untagged.
const int _recentSongLimit = 400;

/// How many artists and genres get their own shelves each day.
const int _shelvesPerFamily = 3;

/// Candidates for those shelves. Beyond the top few, taste is mostly noise.
const int _topCandidates = 10;

/// Songs played within this long are counted as "recent", not as fresh.
const Duration _recentPlay = Duration(days: 14);

/// An imported play is years old, so it's a hint rather than a current favourite.
const double _importedPlayWeight = 0.3;

/// Moods that weigh on a shelf when there are too many of them.
const Set<String> _heavyMoods = {'sad', 'dark', 'angry'};

/// A shelf that isn't about a mood holds at most this many songs with a heavy one.
const int _maxHeavySongs = 3;

/// The moods given a shelf of their own, and what those shelves are called.
const Map<String, String> _moodTitles = {
  'happy': 'Feel good',
  'uplifting': 'Lift your mood',
  'calm': 'Take it easy',
  'energetic': 'Keep moving',
  'romantic': 'Close to you',
  'nostalgic': 'Way back',
  'dreamy': 'Drift away',
  'party': 'Turn it up',
  'focus': 'Get in the zone',
  'sad': 'In your feelings',
};

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
  mood,
  pastYears,
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

/// The day Home was last rebuilt for: Home changes at least once for each of these.
String homeDayKey(DateTime now) => '${now.year}-${now.month}-${now.day}';

/// What groups a song with others on a shelf. Songs with no real album aren't related
/// to each other, even though the server files them all under the same "unknown" one.
String _albumKey(Song song) =>
    song.album.toLowerCase().contains('unknown album')
    ? song.id
    : song.albumId ?? song.album;

/// The songs of the newest albums, newest first. Counting albums rather than songs means
/// one big upload can't push out every other new album. Empty if the server gave no dates.
List<Song> newestSongs(List<Song> library, {int albums = kRecentAlbumPool}) {
  final dated = [
    for (final song in library)
      if (song.addedAt != null) song,
  ]..sort((a, b) => b.addedAt!.compareTo(a.addedAt!));
  final seen = <String>{};
  final picked = <Song>[];
  for (final song in dated) {
    final album = _albumKey(song);
    if (!seen.contains(album) && seen.length >= albums) break;
    seen.add(album);
    picked.add(song);
    if (picked.length >= _recentSongLimit) break;
  }
  return List.unmodifiable(picked);
}

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
    this.moodsById = const {},
    this.similarArtists = const {},
    this.importedTaste = const {},
    this.pastFavourites = const {},
    this.recentlyShown = const {},
    int? seed,
  }) : pool = [
         for (final song in pool)
           if (!lessSongs.contains(song.id) &&
               !lessArtists.contains(song.artist))
             song,
       ],
       _random = Random(seed ?? _seedFor(homeRotationKey(now, events.length))) {
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

  /// What the AI said about each song, by song ID. Empty when AI is off.
  final Map<String, List<String>> moodsById;

  /// Artists the AI says are alike. Every name here is in the library.
  final Map<String, List<String>> similarArtists;

  /// Plays per artist from elsewhere, such as a Spotify export.
  final Map<String, double> importedTaste;

  /// Songs you played a lot in past years, by year.
  final Map<int, List<Song>> pastFavourites;

  /// What Home was showing until now. These only return if there's nothing else to show,
  /// so a new Home looks new.
  final Set<String> recentlyShown;
  final Set<String> _onOtherShelves = {};
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
  double scoreOf(Song song) => _scoreOfId(song.id);

  double _scoreOfId(String id) =>
      (_plays[id] ?? _serverPlays[id] ?? 0) -
      (_skips[id] ?? 0) * _skipPenalty +
      (starred.contains(id) ? _starBonus : 0);

  /// This person's taste, for ordering things outside Home by it too.
  TasteProfile taste() => TasteProfile(
    songs: Map.unmodifiable({
      for (final id in {
        ..._plays.keys,
        ..._serverPlays.keys,
        ..._skips.keys,
        ...starred,
      })
        id: _scoreOfId(id),
    }),
    artists: Map.unmodifiable(_artistTaste()),
  );

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

  /// Taste per artist in the library, including what was imported from elsewhere.
  Map<String, double> _artistTaste() {
    final totals = _affinity(_artistOf);
    if (importedTaste.isEmpty) return totals;
    final inLibrary = pool.map(_artistOf).whereType<String>().toSet();
    importedTaste.forEach((artist, plays) {
      if (inLibrary.contains(artist)) {
        totals[artist] =
            (totals[artist] ?? 0) + log(1 + plays) * _importedPlayWeight;
      }
    });
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

  bool _isHeavy(Song song) =>
      moodsById[song.id]?.any(_heavyMoods.contains) ?? false;

  /// Songs not seen lately first, then those on the Home being replaced, and last those
  /// already on another shelf. Otherwise keeps the order, so ranking still counts.
  List<Song> _unseenFirst(Iterable<Song> songs) {
    int tier(Song song) => _onOtherShelves.contains(song.id)
        ? 2
        : recentlyShown.contains(song.id)
        ? 1
        : 0;
    final list = songs.toList();
    return [
      for (final level in const [0, 1, 2])
        for (final song in list)
          if (tier(song) == level) song,
    ];
  }

  /// Keeps songs in order, leaving out any that would put too many from one artist or
  /// album on a shelf, up to [limit]. Songs in [first] get the first chance. Unless
  /// [preferUnseen] is off, repeats only appear when there's nothing else to fill with.
  List<Song> _varied(
    Iterable<Song> songs, {
    int limit = kShelfSize,
    bool isMoodShelf = false,
    bool preferUnseen = true,
    List<Song> first = const [],
  }) {
    final placed = {for (final song in first) song.id};
    final others = songs.where((song) => !placed.contains(song.id));
    final ordered = [
      ...first,
      ...(preferUnseen ? _unseenFirst(others) : others),
    ];
    final artists = <String, int>{};
    final albums = <String, int>{};
    var heavy = 0;
    final picked = <Song>[];
    final leftOut = <Song>[];
    for (final song in ordered) {
      if (picked.length >= limit) break;
      final artist = song.artist;
      final album = _albumKey(song);
      if ((artists[artist] ?? 0) >= kMaxPerArtist ||
          (albums[album] ?? 0) >= kMaxPerArtist ||
          (!isMoodShelf && _isHeavy(song) && heavy >= _maxHeavySongs)) {
        leftOut.add(song);
        continue;
      }
      if (_isHeavy(song)) heavy++;
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
    // Favourites keep their share, but ones not shown lately get it first.
    final picked = _varied(
      fresh,
      first: _unseenFirst(familiar).take(familiarSlots).toList(),
    );
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
      // This one is simply what you played last, so it's allowed to stay the same.
      _varied([for (final id in ids) ?_songsById[id]], preferUnseen: false),
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
    final similar = similarArtists[artist]?.toSet() ?? const <String>{};
    final genres = pool
        .where((song) => _artistOf(song) == artist)
        .map(_genreOf)
        .whereType<String>()
        .toSet();
    return pool.where(
      (song) =>
          _artistOf(song) == artist ||
          similar.contains(_artistOf(song)) ||
          // Genres are a weaker clue, used when the AI hasn't said who's alike.
          (similar.isEmpty &&
              _genreOf(song) != null &&
              genres.contains(_genreOf(song))),
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
      final album = _albumKey(song);
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
    final mixed = _varied(
      similar.toList()..shuffle(_random),
      // What makes this mix yours, so these aren't given up to other shelves.
      first: _unseenFirst(habit..shuffle(_random)).take(habitSlots).toList(),
    );
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
    final played = _artistTaste().keys.toSet();
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

  /// Songs you loved in a past year, a different year on different days.
  HomeShelf? _pastYear() {
    final years =
        pastFavourites.keys
            .where((year) => pastFavourites[year]!.length >= kMinShelfSongs)
            .toList()
          ..sort();
    if (years.isEmpty) return null;
    final year = years[_random.nextInt(years.length)];
    final songs = [...pastFavourites[year]!]..shuffle(_random);
    return _shelf(
      ShelfKind.pastYears,
      'You played these a lot in $year',
      _varied(songs),
    );
  }

  /// A shelf for each of a few moods, different ones on different days.
  List<HomeShelf> _moodShelves() {
    if (moodsById.isEmpty) return const [];
    final byMood = <String, List<Song>>{};
    for (final song in pool) {
      if (_isWornOut(song)) continue;
      for (final mood in moodsById[song.id] ?? const <String>[]) {
        if (_moodTitles.containsKey(mood)) (byMood[mood] ??= []).add(song);
      }
    }
    final moods = byMood.keys.toList()
      ..sort()
      ..shuffle(_random);
    final shelves = <HomeShelf>[];
    for (final mood in moods) {
      if (shelves.length >= _shelvesPerFamily) break;
      final songs = byMood[mood]!..shuffle(_random);
      final shelf = _shelf(
        ShelfKind.mood,
        _moodTitles[mood]!,
        _varied(songs, isMoodShelf: true),
      );
      if (shelf != null) shelves.add(shelf);
    }
    return shelves;
  }

  /// One song each from the newest albums, so new music comes first (still within the
  /// limit per artist, so one artist's albums can't take over), then a
  /// changing selection from the other recent albums, so one big upload can't fill the
  /// shelf and each Home shows something else.
  HomeShelf? _recentlyAddedShelf() {
    final byAlbum = <String, List<Song>>{};
    for (final song in recentlyAdded) {
      if (lessSongs.contains(song.id) || lessArtists.contains(song.artist)) {
        continue;
      }
      (byAlbum[_albumKey(song)] ??= []).add(song);
    }
    final tracks = {
      for (final entry in byAlbum.entries)
        entry.key: _unseenFirst(entry.value..shuffle(_random)),
    };
    final albums = tracks.keys.toList();
    final newest = albums.take(_newestAlbumsKept).toList();
    final older = albums.skip(_newestAlbumsKept).toList()..shuffle(_random);
    final firstFromEach = <Song>[];
    final theRest = <Song>[];
    for (final album in [...newest, ...older]) {
      firstFromEach.addAll(tracks[album]!.take(kMaxPerArtist));
      theRest.addAll(tracks[album]!.skip(kMaxPerArtist));
    }
    return _shelf(
      ShelfKind.recentlyAdded,
      'Recently added',
      _varied(
        [...firstFromEach, ...theRest],
        first: [for (final album in newest) tracks[album]!.first],
      ),
    );
  }

  HomeShelf? _shelf(ShelfKind kind, String title, List<Song> songs) {
    if (songs.length < kMinShelfSongs) return null;
    _onOtherShelves.addAll(songs.map((song) => song.id));
    return HomeShelf(kind, title, songs);
  }

  /// The shelves to show. [Jump back in] always leads; the rest rotate daily unless
  /// [keepOrder] holds the user's own arrangement of each kind of shelf.
  List<HomeShelf> build({List<ShelfKind>? keepOrder}) {
    final recent = _recentlyAddedShelf();
    final taste = _artistTaste();
    final hasTaste = taste.isNotEmpty;
    final completedPlays =
        events.where((event) => event.kind == PlayKind.completed).length +
        _serverPlays.length +
        importedTaste.length;
    if (completedPlays < kMinPlaysForPersonal || !hasTaste) {
      return List.unmodifiable(
        [_jumpBack(), recent, _discover(), _newToYou()].whereType<HomeShelf>(),
      );
    }
    final favourites = _favourites(taste, count: _shelvesPerFamily * 2);
    final rotating = [
      ..._becauseYouPlayed(favourites.take(_shelvesPerFamily).toList()),
      ..._moreFrom(favourites.skip(_shelvesPerFamily).toList()),
      ..._topGenres(),
      _rediscover(),
      _timeOfDay(),
      recent,
      _discover(),
      _newToYou(),
      ..._moodShelves(),
      _pastYear(),
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
