import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/lyrics.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/subsonic_client.dart';

void main() {
  test('parses timed lines in order and ignores metadata tags', () {
    final lyrics = Lyrics.parseLrc(
      '[ar:Someone]\n[00:12.50]first\n[01:02.5]second\n[00:05.00]zero',
    );
    expect(lyrics.isSynced, isTrue);
    expect(lyrics.lines.map((l) => l.text), ['zero', 'first', 'second']);
    expect(
      lyrics.lines[1].start,
      const Duration(seconds: 12, milliseconds: 500),
    );
  });

  test('plain text becomes unsynced lines', () {
    final lyrics = Lyrics.parsePlain('one\n\ntwo');
    expect(lyrics.isSynced, isFalse);
    expect(lyrics.lines.map((l) => l.text), ['one', '', 'two']);
  });

  test('activeIndex follows the position', () {
    final lyrics = Lyrics.parseLrc('[00:10.00]a\n[00:20.00]b');
    expect(lyrics.activeIndex(const Duration(seconds: 3)), -1);
    expect(lyrics.activeIndex(const Duration(seconds: 10)), 0);
    expect(lyrics.activeIndex(const Duration(seconds: 25)), 1);
  });

  test('multiple stamps on one line repeat it', () {
    final lyrics = Lyrics.parseLrc('[00:01.00][00:09.00]chorus');
    expect(lyrics.lines.length, 2);
  });

  test('an LRC offset moves lines sooner and never below zero', () {
    final lyrics = Lyrics.parseLrc(
      '[offset:+500]\n[00:00.20]early\n[00:10.00]later',
    );
    expect(lyrics.lines[0].start, Duration.zero);
    expect(lyrics.lines[1].start, const Duration(milliseconds: 9500));
  });

  test('a negative LRC offset moves lines later', () {
    final lyrics = Lyrics.parseLrc('[offset:-250]\n[00:01.00]a');
    expect(lyrics.lines.single.start, const Duration(milliseconds: 1250));
  });

  group('LyricsService', () {
    late Directory dir;
    const song = Song(
      id: 'song-1',
      title: 'Title',
      artist: 'Artist',
      album: 'Album',
      durationSeconds: 100,
    );

    setUp(() => dir = Directory.systemTemp.createTempSync('lyrics'));
    tearDown(() => dir.deleteSync(recursive: true));

    SubsonicClient clientReturning(http.Client transport) => SubsonicClient(
      baseUrl: 'http://server',
      username: 'u',
      password: 'p',
      httpClient: transport,
    );

    http.Response subsonicLyrics(List<Map<String, Object?>> lists) =>
        http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'lyricsList': {'structuredLyrics': lists},
            },
          }),
          200,
        );

    test('saved lyrics work with the server and internet down', () async {
      final online = MockClient((request) async {
        if (request.url.host == 'lrclib.net') {
          return http.Response(
            jsonEncode({'syncedLyrics': '[00:01.00]saved line'}),
            200,
          );
        }
        return subsonicLyrics(const []);
      });
      final client = clientReturning(online);
      final first = LyricsService(httpClient: online, store: LyricsStore(dir));
      expect(
        (await first.forSong(client, song))!.lines.single.text,
        'saved line',
      );

      final offline = MockClient((_) async => throw const SocketException('x'));
      final restarted = LyricsService(
        httpClient: offline,
        store: LyricsStore(dir),
      );
      final found = await restarted.forSong(clientReturning(offline), song);
      expect(found!.lines.single.text, 'saved line');
    });

    test('a network failure is not remembered as "no lyrics"', () async {
      var isDown = true;
      final transport = MockClient((request) async {
        if (isDown) throw const SocketException('down');
        if (request.url.host == 'lrclib.net') {
          return http.Response(jsonEncode({'plainLyrics': 'back'}), 200);
        }
        return subsonicLyrics(const []);
      });
      final service = LyricsService(
        httpClient: transport,
        store: LyricsStore(dir),
      );
      final client = clientReturning(transport);

      expect(await service.forSong(client, song), isNull);
      isDown = false;
      expect((await service.forSong(client, song))!.lines.single.text, 'back');
    });

    test('a real "no lyrics" answer is remembered, then rechecked', () async {
      var calls = 0;
      final transport = MockClient((request) async {
        if (request.url.host == 'lrclib.net') {
          calls++;
          return http.Response('', 404);
        }
        return subsonicLyrics(const []);
      });
      var now = DateTime(2026, 1, 1);
      LyricsService fresh() => LyricsService(
        httpClient: transport,
        store: LyricsStore(dir, now: () => now),
      );
      final client = clientReturning(transport);

      expect(await fresh().forSong(client, song), isNull);
      final callsPerLookup = calls;
      expect(await fresh().forSong(client, song), isNull);
      expect(calls, callsPerLookup);

      now = now.add(kNoLyricsRetryAfter + const Duration(minutes: 1));
      expect(await fresh().forSong(client, song), isNull);
      expect(calls, callsPerLookup * 2);
    });

    test(
      'falls back to a search and prefers timed lyrics of the right length',
      () async {
        final transport = MockClient((request) async {
          if (request.url.host != 'lrclib.net') return subsonicLyrics(const []);
          if (request.url.path == '/api/get') return http.Response('', 404);
          return http.Response(
            jsonEncode([
              {'duration': 400, 'syncedLyrics': '[00:01.00] live version'},
              {'duration': song.durationSeconds, 'plainLyrics': 'plain'},
              {
                'duration': song.durationSeconds + 2,
                'syncedLyrics': '[00:02.00] studio version',
              },
            ]),
            200,
          );
        });
        final service = LyricsService(httpClient: transport);
        final found = await service.forSong(clientReturning(transport), song);
        expect(found!.isSynced, isTrue);
        expect(found.lines.single.text, 'studio version');
      },
    );

    test('cleans feat. and remaster noise from titles and artists', () {
      expect(cleanLyricsTitle('Song (feat. Guest) - 2011 Remaster'), 'Song');
      expect(cleanLyricsTitle('Song [Deluxe]'), 'Song');
      expect(primaryLyricsArtist('Main & Other'), 'Main');
      expect(primaryLyricsArtist('Main feat. Other'), 'Main');
    });

    test('a damaged saved file only costs another lookup', () async {
      final transport = MockClient((request) async {
        if (request.url.host == 'lrclib.net') {
          return http.Response(jsonEncode({'plainLyrics': 'fresh'}), 200);
        }
        return subsonicLyrics(const []);
      });
      final store = LyricsStore(dir);
      await store.write(song.id, const LyricsLookup.none());
      for (final file in dir.listSync().whereType<File>()) {
        file.writeAsStringSync('{not json');
      }
      final service = LyricsService(httpClient: transport, store: store);
      final found = await service.forSong(clientReturning(transport), song);
      expect(found!.lines.single.text, 'fresh');
    });

    test(
      'remembers finished lyrics so the player can show them at once',
      () async {
        // Arrange
        final transport = MockClient(
          (_) async => subsonicLyrics(const [
            {
              'synced': true,
              'line': [
                {'start': 1000, 'value': 'known line'},
              ],
            },
          ]),
        );
        final service = LyricsService(httpClient: transport);
        final before = service.peek(song.id);

        // Act
        await service.forSong(clientReturning(transport), song);

        // Assert
        expect(before, isNull);
        expect(service.peek(song.id)!.lines.single.text, 'known line');
      },
    );

    test('server lyrics honour the offset field', () async {
      final transport = MockClient(
        (_) async => subsonicLyrics(const [
          {
            'synced': true,
            'offset': 1000,
            'line': [
              {'start': 5000, 'value': 'line'},
            ],
          },
        ]),
      );
      final lyrics = await clientReturning(transport).lyricsFor('x');
      expect(lyrics!.lines.single.start, const Duration(seconds: 4));
    });
  });
}
