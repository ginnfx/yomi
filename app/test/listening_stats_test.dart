import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/listening/history_api.dart';
import 'package:yomi/core/listening/listening_stats.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/spotify/spotify_export.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/listening_log.dart';

ListenEvent _listen(
  String id,
  DateTime at, {
  String artist = 'A',
  String title = 'T',
  String? genre,
  int seconds = 180,
  PlayKind kind = PlayKind.completed,
}) => ListenEvent(
  id: id,
  songId: 's$title',
  artist: artist,
  title: title,
  album: 'Al',
  genre: genre,
  at: at,
  kind: kind,
  seconds: seconds,
);

void main() {
  group('stats', () {
    final now = DateTime(2026, 6, 15, 12);

    test('adds up completed plays, leaving skips out', () {
      final stats = computeStats(
        [
          _listen('1', DateTime(2026, 6, 14, 9), seconds: 120),
          _listen('2', DateTime(2026, 6, 14, 9, 30), seconds: 240),
          _listen(
            '3',
            DateTime(2026, 6, 14, 10),
            kind: PlayKind.skipped,
            seconds: 5,
          ),
        ],
        range: const StatsRange.all(),
        now: now,
      );
      expect(stats.plays, 2);
      expect(stats.minutes, 6);
      expect(stats.byHour[9], 2);
      expect(stats.byHour[10], 0);
    });

    test('ranks top songs, artists and genres', () {
      final stats = computeStats(
        [
          for (var i = 0; i < 3; i++)
            _listen(
              'a$i',
              DateTime(2026, 6, 1, i),
              artist: 'Big',
              title: 'Hit',
              genre: 'Pop',
            ),
          _listen(
            'b',
            DateTime(2026, 6, 2),
            artist: 'Small',
            title: 'Miss',
            genre: 'Rock',
          ),
        ],
        range: const StatsRange.all(),
        now: now,
      );
      expect(stats.topSongs.first.title, 'Hit');
      expect(stats.topSongs.first.plays, 3);
      expect(stats.topArtists.first.name, 'Big');
      expect(stats.topGenres.first.name, 'Pop');
    });

    test('filters by year and month', () {
      final events = [
        _listen('1', DateTime(2025, 12, 31)),
        _listen('2', DateTime(2026, 1, 1)),
        _listen('3', DateTime(2026, 6, 1)),
      ];
      expect(
        computeStats(
          events,
          range: const StatsRange.year(2026),
          now: now,
        ).plays,
        2,
      );
      expect(
        computeStats(
          events,
          range: const StatsRange.month(2026, 6),
          now: now,
        ).plays,
        1,
      );
    });

    test('counts streaks of days', () {
      final stats = computeStats(
        [
          _listen('1', DateTime(2026, 6, 1)),
          _listen('2', DateTime(2026, 6, 2)),
          _listen('3', DateTime(2026, 6, 3)),
          _listen('3b', DateTime(2026, 6, 3, 18)),
          _listen('4', DateTime(2026, 6, 14)),
          _listen('5', DateTime(2026, 6, 15)),
        ],
        range: const StatsRange.all(),
        now: now,
      );
      expect(stats.longestStreak, 3);
      expect(stats.currentStreak, 2);
      expect(stats.activeDays, 5);
    });

    test('a streak ending yesterday still counts until today is over', () {
      final stats = computeStats(
        [_listen('1', DateTime(2026, 6, 14))],
        range: const StatsRange.all(),
        now: now,
      );
      expect(stats.currentStreak, 1);
      expect(
        computeStats(
          [_listen('1', DateTime(2026, 6, 10))],
          range: const StatsRange.all(),
          now: now,
        ).currentStreak,
        0,
      );
    });

    test('moods come from whatever labels are supplied', () {
      final stats = computeStats(
        [
          _listen('1', DateTime(2026, 6, 1), title: 'Sad one'),
          _listen('2', DateTime(2026, 6, 2), title: 'Sad one'),
          _listen('3', DateTime(2026, 6, 3), title: 'Other'),
        ],
        range: const StatsRange.all(),
        now: now,
        moodsOf: (event) => event.title == 'Sad one' ? ['sad'] : ['calm'],
      );
      expect(stats.topMoods.first.name, 'sad');
    });

    test('Spotify history counts in the same totals', () {
      final imported = ImportedHistory.empty().adding(
        parseHistoryFile(
          jsonEncode([
            for (var i = 0; i < 4; i++)
              {
                'ts': '2021-03-1${i}T20:00:00Z',
                'ms_played': 120000,
                'master_metadata_track_name': 'Old favourite',
                'master_metadata_album_artist_name': 'Old band',
              },
          ]),
        ),
      );
      final stats = computeStats(
        [_listen('1', DateTime(2021, 3, 1, 9), artist: 'Now', title: 'New')],
        range: const StatsRange.year(2021),
        now: now,
        imported: imported,
      );
      expect(stats.plays, 5);
      expect(stats.minutes, 11);
      expect(stats.topSongs.first.title, 'Old favourite');
      expect(stats.topArtists.first.name, 'Old band');
      expect(stats.byHour[20], 4);
    });

    test('a song in both sources is one song in the ranking', () {
      final imported = ImportedHistory.empty().adding(
        parseHistoryFile(
          jsonEncode([
            {
              'ts': '2021-03-10T20:00:00Z',
              'ms_played': 120000,
              'master_metadata_track_name': 'Same Song',
              'master_metadata_album_artist_name': 'Same Band',
            },
          ]),
        ),
      );
      final stats = computeStats(
        [
          _listen(
            '1',
            DateTime(2021, 3, 1),
            artist: 'same band',
            title: 'same song',
          ),
        ],
        range: const StatsRange.all(),
        now: now,
        imported: imported,
      );
      expect(stats.topSongs, hasLength(1));
      expect(stats.topSongs.first.plays, 2);
    });

    test('an empty period is all zeros, not a failure', () {
      final stats = computeStats(
        const [],
        range: const StatsRange.all(),
        now: now,
      );
      expect(stats.isEmpty, isTrue);
      expect(stats.byHour, hasLength(24));
    });
  });

  group('listening log', () {
    late Directory dir;
    late List<Map<String, Object?>> server;
    late Map<String, Object?> imported;
    var isDown = false;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('log');
      server = [];
      imported = {};
      isDown = false;
    });
    tearDown(() => dir.delete(recursive: true));

    HistoryApi api() => HistoryApi(
      serverUrl: 'http://server:4533',
      auth: SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'p'),
      port: 4534,
      httpClient: MockClient((request) async {
        if (isDown) throw http.ClientException('down');
        if (request.url.path == '/v1/history/imported') {
          if (request.method == 'PUT') {
            imported = jsonDecode(request.body) as Map<String, Object?>;
            return http.Response('{"status":"ok"}', 200);
          }
          return http.Response.bytes(utf8.encode(jsonEncode(imported)), 200);
        }
        if (request.method == 'POST') {
          final events = (jsonDecode(request.body) as Map)['events'] as List;
          var added = 0;
          for (final event in events.cast<Map<String, Object?>>()) {
            if (!server.any((other) => other['id'] == event['id'])) {
              server.add(event);
              added++;
            }
          }
          return http.Response('{"added":$added}', 200);
        }
        final after = int.parse(request.url.queryParameters['after'] ?? '0');
        final page = server.skip(after).take(1000).toList();
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({'events': page, 'next': after + page.length}),
          ),
          200,
        );
      }),
    );

    Future<PlayHistory> historyWith(List<String> titles) async {
      final history = PlayHistory(File('${dir.path}/h.json'));
      for (final (i, title) in titles.indexed) {
        await history.record(
          Song(
            id: title,
            title: title,
            artist: 'A',
            album: 'B',
            durationSeconds: 200,
          ),
          PlayKind.completed,
          DateTime(2026, 6, 1, 8, i),
        );
      }
      return history;
    }

    ListeningLog log(PlayHistory history) =>
        ListeningLog(directory: dir, history: history);

    test('uploads plays once, however often it syncs', () async {
      final history = await historyWith(['one', 'two']);
      final listening = log(history);
      await listening.attach(api(), 'account');
      await listening.sync();
      await listening.sync();

      expect(server, hasLength(2));
      expect(server.first['title'], 'one');
      expect(listening.events, hasLength(2));
    });

    test('a new device gets plays made elsewhere', () async {
      final first = log(await historyWith(['one']));
      await first.attach(api(), 'account');
      await first.sync();

      final other = await Directory.systemTemp.createTemp('other');
      addTearDown(() => other.delete(recursive: true));
      final second = ListeningLog(
        directory: other,
        history: PlayHistory(File('${other.path}/h.json')),
      );
      await second.attach(api(), 'account');
      await second.sync();

      expect(second.events.single.title, 'one');
      expect(second.remotePlays.single.kind, PlayKind.completed);
    });

    test('a failed upload is sent again later', () async {
      final history = await historyWith(['one']);
      final listening = log(history);
      await listening.attach(api(), 'account');
      isDown = true;
      await listening.sync();
      expect(server, isEmpty);

      isDown = false;
      await listening.sync();
      expect(server, hasLength(1));
    });

    test('plays survive a restart without any network', () async {
      final history = await historyWith(['one']);
      final first = log(history);
      await first.attach(api(), 'account');
      await first.sync();

      isDown = true;
      final second = log(history);
      await second.attach(api(), 'account');
      expect(second.events, hasLength(1));
    });

    test('importing the same Spotify file twice changes nothing', () async {
      final listening = log(await historyWith(const []));
      await listening.attach(api(), 'account');
      final rows = parseHistoryFile(
        jsonEncode([
          {
            'ts': '2021-03-10T20:00:00Z',
            'ms_played': 120000,
            'master_metadata_track_name': 'S',
            'master_metadata_album_artist_name': 'A',
          },
        ]),
      );
      await listening.importSpotify(rows);
      final total = listening.imported.totalMs;
      await listening.importSpotify(rows);

      expect(listening.imported.totalMs, total);
      expect(imported['months'], isNotNull, reason: 'it reached the server');
    });

    test('imported history comes back on another device', () async {
      final first = log(await historyWith(const []));
      await first.attach(api(), 'account');
      await first.importSpotify(
        parseHistoryFile(
          jsonEncode([
            {
              'ts': '2021-03-10T20:00:00Z',
              'ms_played': 120000,
              'master_metadata_track_name': 'S',
              'master_metadata_album_artist_name': 'A',
            },
          ]),
        ),
      );

      final other = await Directory.systemTemp.createTemp('other2');
      addTearDown(() => other.delete(recursive: true));
      final second = ListeningLog(
        directory: other,
        history: PlayHistory(File('${other.path}/h.json')),
      );
      await second.attach(api(), 'account');
      await second.sync();

      expect(second.imported.totalMs, 120000);
    });

    test('signing out forgets everything on this device', () async {
      final history = await historyWith(['one']);
      final listening = log(history);
      await listening.attach(api(), 'account');
      await listening.sync();

      await listening.attach(null, null);

      expect(listening.events, isEmpty);
      expect(dir.listSync().where((f) => f.path.contains('account')), isEmpty);
    });
  });
}
