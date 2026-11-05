import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/recommendations.dart';

Song _song(
  String id, {
  String artist = 'A',
  String album = 'Al',
  String? genre,
  int plays = 0,
}) => Song(
  id: id,
  title: 'T$id',
  artist: artist,
  album: album,
  albumId: album,
  durationSeconds: 200,
  genre: genre,
  playCount: plays,
);

/// [artists] artists with [albums] albums of [perAlbum] songs each.
List<Song> _library({int artists = 12, int albums = 3, int perAlbum = 6}) => [
  for (var a = 0; a < artists; a++)
    for (var b = 0; b < albums; b++)
      for (var s = 0; s < perAlbum; s++)
        _song(
          '$a-$b-$s',
          artist: 'Artist $a',
          album: 'Album $a-$b',
          genre: 'Genre ${a % 4}',
        ),
];

void main() {
  final now = DateTime(2026, 6, 15, 9);
  final library = _library();

  List<PlayEvent> plays(Iterable<String> ids, {DateTime? at}) => [
    for (final id in ids)
      for (var i = 0; i < 3; i++)
        PlayEvent(
          id,
          at ?? now.subtract(Duration(days: 2, minutes: i)),
          PlayKind.completed,
        ),
  ];

  /// Most plays go to one artist, with a little of everyone else.
  final oneArtistHeavy = [
    ...plays([for (var s = 0; s < 6; s++) '0-0-$s']),
    ...plays(['1-0-0', '2-0-0', '3-0-0', '4-0-0']),
  ];

  HomeBuilder builder({
    List<PlayEvent>? events,
    List<Song>? pool,
    List<Song>? recent,
    DateTime? at,
    Map<String, int> shown = const {},
    Set<String> lessArtists = const {},
    Set<String> lessSongs = const {},
    Set<String> starred = const {},
  }) => HomeBuilder(
    events: events ?? oneArtistHeavy,
    pool: pool ?? library,
    recentlyAdded: recent ?? library.take(40).toList(),
    now: at ?? now,
    shown: shown,
    lessArtists: lessArtists,
    lessSongs: lessSongs,
    starred: starred,
  );

  test('Home is long when there is enough to fill it', () {
    final shelves = builder().build();
    expect(shelves.length, greaterThanOrEqualTo(12));
    expect(shelves.length, lessThanOrEqualTo(kMaxShelves));
    expect(
      shelves.map((s) => s.title).toSet(),
      hasLength(shelves.length),
      reason: 'no two shelves share a title',
    );
  });

  test('no shelf has more than two songs from an artist or album', () {
    for (final shelf in builder().build()) {
      final byArtist = <String, int>{};
      final byAlbum = <String, int>{};
      for (final song in shelf.songs) {
        byArtist[song.artist] = (byArtist[song.artist] ?? 0) + 1;
        byAlbum[song.album] = (byAlbum[song.album] ?? 0) + 1;
      }
      expect(
        byArtist.values.every((count) => count <= kMaxPerArtist),
        isTrue,
        reason: '${shelf.title}: $byArtist',
      );
      expect(
        byAlbum.values.every((count) => count <= kMaxPerArtist),
        isTrue,
        reason: '${shelf.title}: $byAlbum',
      );
    }
  });

  test('a history dominated by one artist still suggests several', () {
    final because = builder()
        .build()
        .where((shelf) => shelf.kind == ShelfKind.becauseYouPlayed)
        .toList();
    expect(because.length, greaterThanOrEqualTo(2));
    expect(because.map((s) => s.title).toSet(), hasLength(because.length));
  });

  test('suggestions are not always led by the top artist', () {
    final titles = <String>{};
    for (var day = 0; day < 20; day++) {
      final shelves = builder(at: now.add(Duration(days: day))).build();
      titles.addAll(
        shelves
            .where((shelf) => shelf.kind == ShelfKind.becauseYouPlayed)
            .map((shelf) => shelf.title),
      );
    }
    expect(titles.length, greaterThan(3));
  });

  test('at least half of a suggested shelf is new to recent listening', () {
    final recentIds = <String>{
      for (final event in oneArtistHeavy) event.songId,
    };
    for (final shelf in builder().build()) {
      if (shelf.kind == ShelfKind.jumpBack) continue;
      final fresh = shelf.songs.where((s) => !recentIds.contains(s.id)).length;
      expect(
        fresh * 2,
        greaterThanOrEqualTo(shelf.songs.length),
        reason: shelf.title,
      );
    }
  });

  test('the same day is stable and the next day differs', () {
    List<String> ids(DateTime at) => [
      for (final shelf in builder(at: at).build())
        for (final song in shelf.songs) song.id,
    ];
    expect(ids(now), ids(now));
    expect(ids(now), isNot(ids(now.add(const Duration(days: 1)))));
  });

  test('songs shown again and again without a play fall away', () {
    final first = builder().build().firstWhere(
      (s) => s.kind == ShelfKind.discover,
    );
    final shown = {for (final song in first.songs) song.id: kShownLimit};
    final next = builder(shown: shown)
        .build()
        .firstWhere((s) => s.kind == ShelfKind.discover);
    final repeats = next.songs.where((s) => shown.containsKey(s.id));
    expect(repeats, isEmpty);
  });

  Set<String> suggestions(List<HomeShelf> shelves) => {
    for (final shelf in shelves)
      if (shelf.kind != ShelfKind.jumpBack)
        for (final song in shelf.songs) song.id,
  };

  test('the next Home mostly avoids what the last one showed', () {
    final first = suggestions(builder().build());
    final next = suggestions(
      HomeBuilder(
        events: oneArtistHeavy,
        pool: library,
        recentlyAdded: library.take(40).toList(),
        now: now,
        recentlyShown: first,
        seed: 7,
      ).build(),
    );
    final overlap = next.intersection(first).length / next.length;
    expect(overlap, lessThan(0.5));
  });

  test('a song rarely appears on more than one shelf', () {
    final shelves = builder().build().where(
      (shelf) => shelf.kind != ShelfKind.jumpBack,
    );
    final all = [
      for (final shelf in shelves)
        for (final song in shelf.songs) song.id,
    ];
    expect(all.toSet().length / all.length, greaterThan(0.8));
  });

  test('different seeds give different shelves from the same history', () {
    Set<String> withSeed(int seed) => suggestions(
      HomeBuilder(
        events: oneArtistHeavy,
        pool: library,
        recentlyAdded: library.take(40).toList(),
        now: now,
        seed: seed,
      ).build(),
    );
    expect(withSeed(1), isNot(withSeed(2)));
  });

  test('a small library still fills its shelves with repeats', () {
    final small = library.take(6).toList();
    final next = HomeBuilder(
      events: const [],
      pool: small,
      recentlyAdded: small,
      now: now,
      recentlyShown: {for (final song in small) song.id},
    ).build();
    expect(next, isNotEmpty);
  });

  test(
    'Recently added always includes the newest albums, and rotates the rest',
    () {
      Song song(int album, int track) => Song(
        id: 'a$album-$track',
        title: 'T',
        artist: 'Artist $album',
        album: 'Album $album',
        albumId: 'album-$album',
        durationSeconds: 100,
      );
      final recent = [
        for (var album = 0; album < 20; album++)
          for (var track = 0; track < 4; track++) song(album, track),
      ];
      HomeShelf shelf({Set<String> shown = const {}, int seed = 1}) =>
          HomeBuilder(
            events: const [],
            pool: recent,
            recentlyAdded: recent,
            now: now,
            recentlyShown: shown,
            seed: seed,
          ).build().firstWhere((s) => s.kind == ShelfKind.recentlyAdded);

      final first = shelf();
      final firstIds = first.songs.map((s) => s.id).toSet();
      expect(first.songs.map((s) => s.album).take(3), [
        'Album 0',
        'Album 1',
        'Album 2',
      ]);

      final next = shelf(shown: firstIds, seed: 2);
      expect(next.songs.map((s) => s.album).take(3), [
        'Album 0',
        'Album 1',
        'Album 2',
      ]);
      final repeats = next.songs.where((s) => firstIds.contains(s.id)).length;
      expect(repeats, lessThan(next.songs.length ~/ 2));
    },
  );

  test('one big upload cannot push every other new album out', () {
    Song track(String album, int i, DateTime at) => Song(
      id: '$album-$i',
      title: 'T',
      artist: album,
      album: album,
      albumId: album,
      durationSeconds: 1,
      addedAt: at,
    );
    final songs = newestSongs([
      for (var i = 0; i < 500; i++) track('box set', i, DateTime(2026, 2)),
      track('older one', 0, DateTime(2026, 1)),
    ]);
    expect(songs.first.album, 'box set');
    final withRoom = newestSongs([
      for (var i = 0; i < 100; i++) track('box set', i, DateTime(2026, 2)),
      track('older one', 0, DateTime(2026, 1)),
    ]);
    expect(withRoom.map((s) => s.album), contains('older one'));
  });

  test('songs with no album are not treated as one big album', () {
    final untagged = [
      for (var i = 0; i < 12; i++)
        Song(
          id: 'u$i',
          title: 'T',
          artist: 'Artist $i',
          album: '[Unknown Album]',
          albumId: 'same',
          durationSeconds: 1,
        ),
    ];
    final shelf = HomeBuilder(
      events: const [],
      pool: untagged,
      recentlyAdded: untagged,
      now: now,
    ).build().firstWhere((s) => s.kind == ShelfKind.recentlyAdded);
    expect(shelf.songs, hasLength(12));
  });

  test('favourites keep their share of a shelf', () {
    final shelf = builder().build().firstWhere(
      (s) => s.kind == ShelfKind.becauseYouPlayed,
    );
    final played = {for (final event in oneArtistHeavy) event.songId};
    expect(shelf.songs.where((s) => played.contains(s.id)), isNotEmpty);
  });

  test('the newest songs come first, and undated ones are left out', () {
    Song dated(String id, DateTime? at) => Song(
      id: id,
      title: id,
      artist: 'A',
      album: 'B',
      durationSeconds: 1,
      addedAt: at,
    );
    final songs = newestSongs([
      dated('old', DateTime(2020)),
      dated('none', null),
      dated('new', DateTime(2026)),
    ]);
    expect(songs.map((s) => s.id), ['new', 'old']);
  });

  test('"show less" removes an artist and a song from suggestions', () {
    final shelves = builder(
      lessArtists: {'Artist 1'},
      lessSongs: {'2-0-0'},
    ).build();
    for (final shelf in shelves) {
      expect(shelf.songs.where((s) => s.artist == 'Artist 1'), isEmpty);
      expect(shelf.songs.where((s) => s.id == '2-0-0'), isEmpty);
    }
  });

  test('a liked song never played counts as taste', () {
    final starredBuilder = builder(
      events: plays(['0-0-0', '0-0-1', '0-0-2', '0-0-3', '0-0-4']),
      starred: {'5-0-0', '5-0-1', '5-0-2', '5-1-0'},
    );
    final because = starredBuilder
        .build()
        .where((shelf) => shelf.kind == ShelfKind.becauseYouPlayed)
        .map((shelf) => shelf.title);
    expect(because.any((title) => title.contains('Artist 5')), isTrue);
  });

  test('the time of day mix favours what you play at this hour', () {
    final morning = DateTime(2026, 6, 14, 9);
    final evening = DateTime(2026, 6, 14, 20);
    final habit = [for (var a = 0; a < 6; a++) '$a-0-0'];
    final events = [
      ...plays(habit, at: morning),
      ...plays([for (var a = 6; a < 12; a++) '$a-0-0'], at: evening),
    ];
    final mix = builder(events: events)
        .build()
        .firstWhere((s) => s.kind == ShelfKind.timeOfDay);
    expect(mix.title, 'Morning mix');
    expect(mix.songs.where((s) => habit.contains(s.id)), isNotEmpty);
    expect(
      mix.songs.where((s) => s.id.startsWith('6-0-0') || s.id == '7-0-0'),
      isEmpty,
    );
  });

  test('Recently added rotates across albums instead of filling from one', () {
    final recent = [
      for (var album = 0; album < 20; album++)
        for (var s = 0; s < 12; s++)
          _song('r$album-$s', artist: 'New $album', album: 'New $album'),
    ];
    final shelf = builder(recent: recent)
        .build()
        .firstWhere((s) => s.kind == ShelfKind.recentlyAdded);
    expect(shelf.songs.map((s) => s.album).toSet().length, greaterThan(5));

    final later = builder(
      recent: recent,
      at: now.add(const Duration(days: 1)),
    ).build().firstWhere((s) => s.kind == ShelfKind.recentlyAdded);
    expect(
      later.songs.map((s) => s.id).toSet(),
      isNot(shelf.songs.map((s) => s.id).toSet()),
    );
  });

  test('play counts from the server personalise a brand new device', () {
    final pool = [
      for (final song in library)
        song.artist == 'Artist 3'
            ? _song(
                song.id,
                artist: song.artist,
                album: song.album,
                genre: song.genre,
                plays: 20,
              )
            : song,
    ];
    final shelves = builder(events: const [], pool: pool).build();
    expect(
      shelves.map((shelf) => shelf.kind),
      contains(ShelfKind.becauseYouPlayed),
    );
  });

  group('with AI labels', () {
    List<HomeShelf> shelvesWith(
      Map<String, List<String>> moods, {
      Map<String, List<String>> similar = const {},
    }) => HomeBuilder(
      events: oneArtistHeavy,
      pool: library,
      recentlyAdded: library.take(60).toList(),
      now: now,
      moodsById: moods,
      similarArtists: similar,
    ).build();

    test('Home gets mood shelves', () {
      final moods = {
        for (final song in library)
          song.id: [song.artist.hashCode.isEven ? 'calm' : 'uplifting'],
      };
      final shelves = shelvesWith(moods);
      expect(shelves.map((s) => s.kind), contains(ShelfKind.mood));
    });

    test('no labels means no mood shelves', () {
      expect(
        shelvesWith(const {}).map((s) => s.kind),
        isNot(contains(ShelfKind.mood)),
      );
    });

    test('sad songs can no longer take over a shelf', () {
      final allSad = {
        for (final song in library) song.id: const ['sad'],
      };
      final moods = {
        ...allSad,
        for (var a = 0; a < 6; a++)
          for (var b = 0; b < 3; b++)
            for (var s = 0; s < 6; s++) '$a-$b-$s': const ['happy'],
      };
      final recent = shelvesWith(moods)
          .firstWhere((shelf) => shelf.kind == ShelfKind.recentlyAdded);
      final heavy = recent.songs.where((s) => moods[s.id]!.contains('sad'));
      expect(heavy.length, lessThanOrEqualTo(3));
    });

    test('similar artists replace the genre guess', () {
      final shelves = shelvesWith(
        const {},
        similar: {
          for (var a = 0; a < 12; a++) 'Artist $a': const ['Artist 11'],
        },
      );
      final because = shelves.where(
        (shelf) =>
            shelf.kind == ShelfKind.becauseYouPlayed &&
            !shelf.title.contains('Artist 11'),
      );
      expect(because, isNotEmpty);
      for (final shelf in because) {
        final seed = shelf.title.replaceFirst('Because you played ', '');
        for (final song in shelf.songs) {
          expect(['Artist 11', seed], contains(song.artist));
        }
      }
    });
  });

  test('a pinned order applies to families and keeps each in order', () {
    final shelves = builder().build(
      keepOrder: const [
        ShelfKind.discover,
        ShelfKind.becauseYouPlayed,
        ShelfKind.jumpBack,
      ],
    );
    expect(shelves.first.kind, ShelfKind.discover);
    final kinds = shelves.map((s) => s.kind).toList();
    expect(
      kinds.lastIndexOf(ShelfKind.becauseYouPlayed),
      lessThan(kinds.indexOf(ShelfKind.jumpBack)),
    );
  });
}
