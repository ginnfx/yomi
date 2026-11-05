import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/genres.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/recommendations.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/home_controller.dart';
import 'package:yomi/state/settings.dart';

Song song(int i, {String artist = 'Artist', String? genre}) => Song(
  id: 's$i',
  title: 'Song $i',
  artist: artist,
  album: 'Album',
  durationSeconds: 100,
  genre: genre,
);

void main() {
  final now = DateTime(2026, 6, 15, 9);

  group('genres', () {
    test('merges spellings of the same genre', () {
      final groups = groupGenres(const [
        Genre('Hip Hop', 10),
        Genre('Hip-Hop', 5),
        Genre('Rap', 2),
        Genre('Jazz', 3),
      ]);
      expect(groups.first.name, 'Hip-Hop');
      expect(groups.first.songCount, 17);
      expect(groups.first.variants, ['Hip Hop', 'Hip-Hop', 'Rap']);
      expect(groups.last.name, 'Jazz');
    });

    test('merges differences of case, and ignores blanks', () {
      final groups = groupGenres(const [
        Genre('jazz', 1),
        Genre('JAZZ', 1),
        Genre('', 9),
        Genre('  ', 9),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.songCount, 2);
    });

    test('filtering keeps everything when nothing is selected', () {
      expect(songMatchesGenres(song(1), const {}), isTrue);
      expect(songMatchesGenres(song(1, genre: 'Rap'), {'Hip-Hop'}), isTrue);
      expect(songMatchesGenres(song(1), {'Hip-Hop'}), isFalse);
    });

    test('a pager walks every variant without repeats', () async {
      final calls = <String>[];
      final client = SubsonicClient(
        baseUrl: 'http://s',
        username: 'u',
        password: 'p',
        httpClient: MockClient((request) async {
          final genre = request.url.queryParameters['genre']!;
          final offset = request.url.queryParameters['offset']!;
          calls.add('$genre@$offset');
          final ids = genre == 'A' && offset == '0'
              ? ['1', '2']
              : genre == 'A'
              ? ['3']
              : ['2', '4'];
          return http.Response(
            '{"subsonic-response":{"status":"ok","songsByGenre":{"song":['
            '${ids.map((id) => '{"id":"$id","title":"t","artist":"a"}').join(',')}'
            ']}}}',
            200,
          );
        }),
      );
      final pager = GenrePager(client, const [
        GenreGroup('G', ['A', 'B'], 5),
      ], pageSize: 2);
      final seen = <String>[];
      while (!pager.isDone) {
        seen.addAll((await pager.nextPage()).map((s) => s.id));
      }
      expect(seen, ['1', '2', '3', '4']);
      expect(calls, contains('A@2'));
    });
  });

  group('HomeBuilder', () {
    final library = [
      for (var i = 0; i < 30; i++)
        song(i, artist: 'Artist ${i % 3}', genre: i % 2 == 0 ? 'Rock' : 'Jazz'),
    ];

    List<PlayEvent> plays(String id, int count, DateTime at) => [
      for (var i = 0; i < count; i++)
        PlayEvent(id, at.add(Duration(minutes: i)), PlayKind.completed),
    ];

    test('a new listener gets general shelves, not empty personal ones', () {
      final shelves = HomeBuilder(
        events: const [],
        pool: library,
        recentlyAdded: library.take(5).toList(),
        now: now,
      ).build();
      expect(shelves.map((s) => s.kind).take(2), [
        ShelfKind.recentlyAdded,
        ShelfKind.discover,
      ]);
      expect(
        shelves.map((s) => s.kind),
        isNot(contains(ShelfKind.becauseYouPlayed)),
      );
    });

    test('an empty library produces no shelves rather than failing', () {
      final shelves = HomeBuilder(
        events: plays('gone', 6, now),
        pool: const [],
        recentlyAdded: const [],
        now: now,
      ).build();
      expect(shelves, isEmpty);
    });

    test('Jump back in leads, with the latest play first', () {
      final shelves = HomeBuilder(
        events: [
          ...plays('s1', 3, now.subtract(const Duration(days: 2))),
          ...plays('s2', 3, now.subtract(const Duration(hours: 1))),
          ...plays('s3', 3, now.subtract(const Duration(days: 1))),
        ],
        pool: library,
        recentlyAdded: const [],
        now: now,
      ).build();
      expect(shelves.first.kind, ShelfKind.jumpBack);
      expect(shelves.first.songs.map((s) => s.id).take(3), ['s2', 's3', 's1']);
    });

    test('shelves name the artist and genre played most', () {
      final shelves = HomeBuilder(
        events: plays('s0', 8, now.subtract(const Duration(hours: 2))),
        pool: library,
        recentlyAdded: const [],
        now: now,
      ).build();
      final titles = shelves.map((s) => s.title);
      expect(titles, contains('Because you played Artist 0'));
      expect(titles, contains('More Rock'));
    });

    test('recent plays outweigh old ones', () {
      final builder = HomeBuilder(
        events: [
          ...plays('s1', 1, now.subtract(const Duration(days: 150))),
          ...plays('s2', 1, now),
        ],
        pool: library,
        recentlyAdded: const [],
        now: now,
      );
      expect(
        builder.scoreOf(library[2]),
        greaterThan(builder.scoreOf(library[1])),
      );
    });

    test('a song mostly skipped is left out of personal shelves', () {
      final events = [
        ...plays('s0', 6, now.subtract(const Duration(hours: 3))),
        for (var i = 0; i < 6; i++)
          PlayEvent('s2', now.subtract(Duration(hours: i)), PlayKind.skipped),
      ];
      final shelves = HomeBuilder(
        events: events,
        pool: library,
        recentlyAdded: const [],
        now: now,
      ).build();
      final genre = shelves.firstWhere((s) => s.kind == ShelfKind.topGenre);
      expect(genre.songs.map((s) => s.id), isNot(contains('s2')));
    });

    test('Rediscover only offers songs not played for a while', () {
      final shelves = HomeBuilder(
        events: [
          ...plays('s1', 2, now.subtract(const Duration(days: 60))),
          ...plays('s2', 2, now.subtract(const Duration(days: 45))),
          ...plays('s3', 2, now.subtract(const Duration(days: 40))),
          ...plays('s4', 2, now),
        ],
        pool: library,
        recentlyAdded: const [],
        now: now,
      ).build();
      final shelf = shelves.firstWhere((s) => s.kind == ShelfKind.rediscover);
      expect(shelf.songs.map((s) => s.id).toSet(), {'s1', 's2', 's3'});
    });

    test('the same day gives the same Home, and another day differs', () {
      final events = plays('s0', 8, now.subtract(const Duration(days: 1)));
      List<ShelfKind> orderOn(DateTime day) => HomeBuilder(
        events: events,
        pool: library,
        recentlyAdded: library.take(5).toList(),
        now: day,
      ).build().map((s) => s.kind).toList();

      expect(orderOn(now), orderOn(now.add(const Duration(hours: 1))));
      final week = {
        for (var d = 0; d < 7; d++)
          orderOn(now.add(Duration(days: d))).join(','),
      };
      expect(week.length, greaterThan(1));
    });

    test('untagged songs still get shelves', () {
      final untagged = [for (var i = 0; i < 20; i++) song(i)];
      final shelves = HomeBuilder(
        events: plays('s0', 8, now),
        pool: untagged,
        recentlyAdded: const [],
        now: now,
      ).build();
      expect(shelves.any((s) => s.kind == ShelfKind.topGenre), isFalse);
      expect(shelves.any((s) => s.kind == ShelfKind.becauseYouPlayed), isTrue);
    });

    test('the user can pin the order', () {
      final shelves =
          HomeBuilder(
            events: [
              ...plays('s0', 4, now),
              ...plays('s1', 4, now),
              ...plays('s2', 4, now),
            ],
            pool: library,
            recentlyAdded: library.take(5).toList(),
            now: now,
          ).build(
            keepOrder: const [
              ShelfKind.recentlyAdded,
              ShelfKind.discover,
              ShelfKind.jumpBack,
            ],
          );
      final pinned = shelves
          .map((s) => s.kind)
          .where(
            const [
              ShelfKind.recentlyAdded,
              ShelfKind.discover,
              ShelfKind.jumpBack,
            ].contains,
          );
      expect(pinned, [
        ShelfKind.recentlyAdded,
        ShelfKind.discover,
        ShelfKind.jumpBack,
      ]);
    });

    test('rotation key changes daily and every few plays', () {
      expect(
        homeRotationKey(now, 1),
        homeRotationKey(now, kPlaysPerRefresh - 1),
      );
      expect(
        homeRotationKey(now, 1),
        isNot(homeRotationKey(now, kPlaysPerRefresh)),
      );
      expect(
        homeRotationKey(now, 1),
        isNot(homeRotationKey(now.add(const Duration(days: 1)), 1)),
      );
    });

    test('time of day titles follow the clock', () {
      expect(timeOfDayTitle(DateTime(2026, 1, 1, 8)), 'Morning mix');
      expect(timeOfDayTitle(DateTime(2026, 1, 1, 14)), 'Afternoon mix');
      expect(timeOfDayTitle(DateTime(2026, 1, 1, 19)), 'Evening mix');
      expect(timeOfDayTitle(DateTime(2026, 1, 1, 2)), 'Late night mix');
    });
  });

  group('HomeController', () {
    late Directory dir;
    var requests = 0;
    var isDown = false;
    late DateTime clock;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('home');
      requests = 0;
      isDown = false;
      clock = now;
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => dir.deleteSync(recursive: true));

    SubsonicClient client() => SubsonicClient(
      baseUrl: 'http://s',
      username: 'u',
      password: 'p',
      httpClient: MockClient((request) async {
        requests++;
        if (isDown) throw const SocketException('down');
        final songs = List.generate(
          6,
          (i) => '{"id":"$i","title":"t$i","artist":"a","genre":"Rock"}',
        ).join(',');
        return http.Response(
          '{"subsonic-response":{"status":"ok",'
          '"randomSongs":{"song":[$songs]},"starred2":{},"albumList2":{}}}',
          200,
        );
      }),
    );

    Future<HomeController> controller() async {
      final prefs = await SharedPreferences.getInstance();
      return HomeController(
        history: PlayHistory(File('${dir.path}/h.json'), now: () => clock),
        settings: SettingsController(prefs),
        cacheFile: File('${dir.path}/home.json'),
        now: () => clock,
      );
    }

    test('the top of Home is saved and returns unchanged after a restart', () async {
      final first = await controller();
      first.attach(client());
      await first.refreshIfDue();
      final picks = [for (final song in first.quickSongs) song.id];
      expect(picks, isNotEmpty);

      requests = 0;
      final second = await controller();
      await second.loadCache();
      second.attach(client());

      expect([for (final song in second.quickSongs) song.id], picks);
      expect(requests, 0);
    });

    test('a background refresh waits instead of changing what is showing', () async {
      final home = await controller();
      home.attach(client());
      await home.refreshIfDue();
      final before = home.shelves;

      clock = clock.add(const Duration(days: 1));
      await home.refreshIfDue();
      expect(identical(home.shelves.first, before.first), isTrue);

      home.applyHeldBack();
      expect(identical(home.shelves.first, before.first), isFalse);
    });

    test('pulling to refresh shows the new version straight away', () async {
      final home = await controller();
      home.attach(client());
      await home.refreshIfDue();
      final before = home.shelves;

      await home.refresh();

      expect(identical(home.shelves.first, before.first), isFalse);
    });

    test('opens from disk without asking the server', () async {
      final first = await controller();
      first.attach(client());
      await first.refreshIfDue();
      expect(first.shelves, isNotEmpty);

      requests = 0;
      final second = await controller();
      await second.loadCache();
      second.attach(client());
      await Future<void>.delayed(Duration.zero);
      expect(second.shelves, isNotEmpty);
      expect(requests, 0);
    });

    test('a new day rebuilds', () async {
      final home = await controller();
      home.attach(client());
      await home.refreshIfDue();
      requests = 0;
      await home.refreshIfDue();
      expect(requests, 0);

      clock = clock.add(const Duration(days: 1));
      await home.refreshIfDue();
      expect(requests, greaterThan(0));
    });

    test('a failed refresh keeps the shelves on screen', () async {
      final home = await controller();
      home.attach(client());
      await home.refreshIfDue();
      final before = home.shelves;
      expect(before, isNotEmpty);

      isDown = true;
      await home.refresh();
      expect(home.shelves.map((s) => s.title), before.map((s) => s.title));
      expect(home.error, isNotNull);
    });

    test('signing out clears Home, even if a rebuild was running', () async {
      final home = await controller();
      home.attach(client());
      final running = home.refresh();
      home.attach(null);
      await running;
      expect(home.shelves, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(File('${dir.path}/home.json').existsSync(), isFalse);
    });

    test('hidden shelves stay hidden', () async {
      final home = await controller();
      home.attach(client());
      await home.refreshIfDue();
      await home.settings.setHomeHidden({'discover'});
      expect(home.shelves.any((s) => s.kind == ShelfKind.discover), isFalse);
    });
  });
}
