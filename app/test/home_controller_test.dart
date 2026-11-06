import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/recommendations.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/home_controller.dart';
import 'package:yomi/state/settings.dart';

http.Response _ok(Map<String, Object?> body) => http.Response(
  jsonEncode({
    'subsonic-response': {'status': 'ok', ...body},
  }),
  200,
);

Song _song(int artist, int index, {DateTime? added}) => Song(
  id: '$artist-$index',
  title: 'Song $artist-$index',
  artist: 'Artist $artist',
  album: 'Album $artist',
  albumId: 'album-$artist',
  durationSeconds: 200,
  genre: 'Genre ${artist % 4}',
  addedAt: added,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late DateTime now;
  late SettingsController settings;
  late List<Song> library;
  late PlayHistory history;
  String? version;
  final made = <HomeController>[];

  SubsonicClient client() => SubsonicClient(
    baseUrl: 'http://music.test',
    username: 'one',
    password: 'pw',
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('getPlaylists')) {
        return _ok({
          'playlists': {'playlist': <Object>[]},
        });
      }
      return _ok({'starred2': <String, Object>{}});
    }),
  );

  HomeController controller() {
    final home = HomeController(
      history: history,
      settings: settings,
      cacheFile: File('${dir.path}/home.json'),
      catalogSongs: () => library,
      libraryVersion: () => version,
      now: () => now,
    );
    made.add(home);
    return home;
  }

  Future<void> settle(HomeController home) async {
    // Lets a rebuild started by a change finish.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await home.refreshIfDue();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<String> shelfIds(HomeController home) => [
    for (final shelf in home.shelves)
      if (shelf.kind != ShelfKind.jumpBack)
        for (final song in shelf.songs) song.id,
  ];

  Set<String> suggested(HomeController home) => shelfIds(home).toSet();

  Future<void> addPlays(int count, {required DateTime at}) async {
    for (var i = 0; i < count; i++) {
      await history.record(
        library[i % library.length],
        PlayKind.completed,
        at.add(Duration(seconds: i)),
      );
    }
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('home_controller');
    now = DateTime(2026, 11, 5, 10);
    version = 'scan-1';
    SharedPreferences.setMockInitialValues({});
    settings = SettingsController(await SharedPreferences.getInstance());
    library = [
      for (var artist = 0; artist < 40; artist++)
        for (var index = 0; index < 6; index++)
          _song(
            artist,
            index,
            added: DateTime(2026, 1, 1).add(Duration(days: artist)),
          ),
    ];
    history = PlayHistory(File('${dir.path}/history.json'), now: () => now);
    await addPlays(30, at: now.subtract(const Duration(days: 3)));
  });

  tearDown(() async {
    for (final home in made) {
      home.dispose();
      await home.saved;
    }
    made.clear();
    await dir.delete(recursive: true);
  });

  Future<HomeController> built() async {
    final home = controller()..attach(client());
    await home.refresh();
    return home;
  }

  test('pulling to refresh gives you different suggestions', () async {
    final home = await built();
    final first = suggested(home);
    await home.refresh();
    final second = suggested(home);
    final overlap = first.intersection(second).length / first.length;
    expect(overlap, lessThan(0.5));
  });

  test(
    'the same day, nothing new: reopening keeps exactly the same Home',
    () async {
      final first = await built();
      final before = shelfIds(first);
      final quick = [for (final song in first.quickSongs) song.id];

      now = now.add(const Duration(hours: 2));
      final reopened = controller();
      await reopened.loadCache();
      reopened.attach(client());
      await settle(reopened);

      expect(shelfIds(reopened), before);
      expect([for (final song in reopened.quickSongs) song.id], quick);
    },
  );

  test('a new day shows a new Home as soon as the app opens', () async {
    final first = await built();
    final before = suggested(first);

    now = now.add(const Duration(days: 1));
    final reopened = controller();
    await reopened.loadCache();
    expect(suggested(reopened), before);
    reopened.attach(client());
    await settle(reopened);

    final overlap = suggested(reopened).intersection(before).length;
    expect(overlap / before.length, lessThan(0.5));
  });

  test('a new Home that arrives mid-use waits until you come back', () async {
    final home = await built();
    final before = shelfIds(home);

    now = now.add(const Duration(minutes: 10));
    await addPlays(kPlaysPerRefresh, at: now);
    await settle(home);
    expect(shelfIds(home), before);

    home.applyHeldBack();
    expect(shelfIds(home), isNot(before));
  });

  test('coming back after a long time away is treated like opening', () async {
    final home = await built();
    final before = shelfIds(home);

    now = now.add(const Duration(days: 1));
    home.appOpened();
    await settle(home);

    expect(shelfIds(home), isNot(before));
  });

  test('keeps the taste it built, and forgets it on sign-out', () async {
    final home = await built();
    expect(home.taste.isEmpty, isFalse);
    expect(home.taste.of(library.first), greaterThan(0));

    home.attach(null);
    expect(home.taste.isEmpty, isTrue);
  });

  test('new plays still count once the history is full', () async {
    await history.clear();
    final file = File('${dir.path}/history.json');
    await file.writeAsString(
      jsonEncode({
        'events': [
          for (var i = 0; i < kHistoryMaxEvents; i++)
            PlayEvent(
              library[i % library.length].id,
              now.subtract(Duration(hours: 1, seconds: i)),
              PlayKind.completed,
            ).toJson(),
        ],
        'songs': [for (final song in library) song.toJson()],
      }),
    );
    await history.load();
    final home = await built();
    final before = shelfIds(home);

    now = now.add(const Duration(minutes: 10));
    await addPlays(kPlaysPerRefresh, at: now);
    expect(history.events.length, kHistoryMaxEvents);
    await settle(home);
    home.applyHeldBack();

    expect(shelfIds(home), isNot(before));
  });

  test('a song added to the library reaches Recently added', () async {
    final home = await built();
    final fresh = _song(99, 0, added: DateTime(2026, 11, 5));
    library = [...library, fresh];
    version = 'scan-2';

    now = now.add(const Duration(seconds: 1));
    home.appOpened();
    await settle(home);

    final recent = home.shelves.firstWhere(
      (shelf) => shelf.kind == ShelfKind.recentlyAdded,
    );
    expect(recent.songs.map((song) => song.id), contains(fresh.id));
  });

  test(
    'a song stops being counted as ignored only after a later play',
    () async {
      library = [
        for (var i = 0; i < 8; i++) _song(i, 0, added: DateTime(2026)),
      ];
      await history.clear();
      await addPlays(8, at: now.subtract(const Duration(days: 40)));

      Map<String, Object?> records() =>
          jsonDecode(
                File('${dir.path}/home.json').readAsStringSync(),
              )['shownAt']
              as Map<String, Object?>;
      int times(String id) =>
          ((records()[id] as Map<String, Object?>?)?['times'] as int?) ?? 0;

      final home = await built();
      await home.refresh();
      final song = library.first;
      // Played long before Home showed it, so that old play doesn't excuse it.
      expect(times(song.id), 2);

      now = now.add(const Duration(minutes: 1));
      await history.record(song, PlayKind.completed, now);
      now = now.add(const Duration(minutes: 1));
      await home.refresh();
      expect(times(song.id), 1);
    },
  );

  test(
    'a song rested for being shown too often comes back eventually',
    () async {
      library = [
        for (var i = 0; i < 8; i++) _song(i, 0, added: DateTime(2026)),
      ];
      await history.clear();
      final home = await built();
      final song = library.first;
      Map<String, Object?> records() =>
          jsonDecode(
                File('${dir.path}/home.json').readAsStringSync(),
              )['shownAt']
              as Map<String, Object?>;
      await home.refresh();
      expect((records()[song.id] as Map<String, Object?>)['times'], 2);

      now = now.add(kShownRest + const Duration(days: 1));
      await home.refresh();
      expect((records()[song.id] as Map<String, Object?>)['times'], 1);
    },
  );

  test(
    'a Home already out of date is not shown on the way to a newer one',
    () async {
      final home = await built();
      final before = shelfIds(home);

      now = now.add(const Duration(minutes: 10));
      await addPlays(kPlaysPerRefresh, at: now);
      await settle(home);

      now = now.add(const Duration(days: 1));
      home.applyHeldBack();
      expect(shelfIds(home), before);
    },
  );

  test('the top of Home changes along with the rest', () async {
    final home = await built();
    final before = {for (final song in home.quickSongs) song.id};
    await home.refresh();
    final after = {for (final song in home.quickSongs) song.id};
    expect(after.intersection(before), isEmpty);
    expect(after, hasLength(quickPickCount));
  });

  test('"show less" also applies to the top of Home', () async {
    final home = await built();
    final hidden = home.quickSongs.first;
    await home.showLess(hidden, wholeArtist: true);
    await home.refresh();
    expect(
      home.quickSongs.map((song) => song.artist),
      isNot(contains(hidden.artist)),
    );
  });
}
