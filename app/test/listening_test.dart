import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/listening/auto_download_ledger.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/listening/play_tracker.dart';
import 'package:yomi/core/listening/scrobble_queue.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/offline/download_store.dart';
import 'package:yomi/core/offline/file_fetcher.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/download_manager.dart';
import 'package:yomi/state/listening_controller.dart';
import 'package:yomi/state/settings.dart';

const song = Song(
  id: 's1',
  title: 'One',
  artist: 'A',
  album: 'B',
  durationSeconds: 100,
);
const otherSong = Song(
  id: 's2',
  title: 'Two',
  artist: 'A',
  album: 'B',
  durationSeconds: 100,
);

void main() {
  group('PlayTracker', () {
    late List<String> events;
    late PlayTracker tracker;
    final at = DateTime(2026, 1, 1);

    setUp(() {
      events = [];
      tracker = PlayTracker(
        onStarted: (s) => events.add('start:${s.id}'),
        onScrobble: (s, _) => events.add('scrobble:${s.id}'),
        onCompleted: (s, _) => events.add('complete:${s.id}'),
        onSkipped: (s, _) => events.add('skip:${s.id}'),
      );
    });

    void listen(int fromSeconds, int toSeconds, {bool isPlaying = true}) {
      for (var s = fromSeconds; s <= toSeconds; s++) {
        tracker.position(
          Duration(seconds: s),
          isPlaying: isPlaying,
          now: at,
        );
      }
    }

    test('scrobbles at half the song and completes at 80%', () {
      tracker.trackChanged(song, at);
      listen(0, 49);
      expect(events, ['start:s1']);
      listen(50, 50);
      expect(events, ['start:s1', 'scrobble:s1']);
      listen(51, 80);
      expect(events.last, 'complete:s1');
    });

    test('a long song scrobbles after four minutes', () {
      const long = Song(
        id: 'l',
        title: 't',
        artist: 'a',
        album: 'b',
        durationSeconds: 3600,
      );
      tracker.trackChanged(long, at);
      listen(0, 239);
      expect(events, ['start:l']);
      listen(240, 240);
      expect(events.last, 'scrobble:l');
    });

    test('seeking to the end does not count as listening', () {
      tracker.trackChanged(song, at);
      listen(0, 2);
      tracker.position(const Duration(seconds: 95), isPlaying: true, now: at);
      expect(events, ['start:s1']);
    });

    test('paused time does not count', () {
      tracker.trackChanged(song, at);
      listen(0, 90, isPlaying: false);
      expect(events, ['start:s1']);
    });

    test(
      'leaving early counts as a skip; leaving after 30 seconds does not',
      () {
        tracker.trackChanged(song, at);
        listen(0, 10);
        tracker.trackChanged(otherSong, at);
        expect(events, ['start:s1', 'skip:s1', 'start:s2']);

        events.clear();
        listen(0, 35);
        tracker.trackChanged(song, at);
        expect(events, ['start:s1']);
      },
    );

    test('repeat-one counts every loop as its own play', () {
      tracker.trackChanged(song, at);
      listen(0, 99);
      listen(0, 99);
      expect(events.where((e) => e == 'complete:s1').length, 2);
      expect(events.where((e) => e == 'scrobble:s1').length, 2);
    });

    test('pressing previous before completing is not a new play', () {
      tracker.trackChanged(song, at);
      listen(0, 20);
      listen(0, 20);
      expect(events.where((e) => e == 'start:s1').length, 1);
    });

    test('a song with no known length still scrobbles after four minutes', () {
      const unknown = Song(
        id: 'u',
        title: 't',
        artist: 'a',
        album: 'b',
        durationSeconds: 0,
      );
      tracker.trackChanged(unknown, at);
      listen(0, 240);
      expect(events.last, 'scrobble:u');
    });
  });

  group('PlayHistory', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('history'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('survives a restart', () async {
      final file = File('${dir.path}/h.json');
      final history = PlayHistory(file);
      await history.record(song, PlayKind.completed, DateTime(2026, 1, 2));

      final reloaded = PlayHistory(file);
      await reloaded.load();
      expect(reloaded.events.single.songId, 's1');
      expect(reloaded.songFor('s1')!.title, 'One');
    });

    test('forgets old plays and the songs only they referred to', () async {
      final now = DateTime(2026, 6, 1);
      final history = PlayHistory(File('${dir.path}/h.json'), now: () => now);
      await history.record(
        song,
        PlayKind.completed,
        now.subtract(kHistoryKeepFor + const Duration(days: 1)),
      );
      await history.record(otherSong, PlayKind.completed, now);

      expect(history.events.map((e) => e.songId), ['s2']);
      expect(history.songFor('s1'), isNull);
    });

    test('a damaged file starts empty rather than crashing', () async {
      final file = File('${dir.path}/h.json')..writeAsStringSync('{"events":');
      final history = PlayHistory(file);
      await history.load();
      expect(history.events, isEmpty);
    });
  });

  group('ScrobbleQueue', () {
    late Directory dir;
    late List<Uri> requests;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('scrobbles');
      requests = [];
    });
    tearDown(() => dir.deleteSync(recursive: true));

    SubsonicClient clientWith(http.Response Function() answer) =>
        SubsonicClient(
          baseUrl: 'http://server',
          username: 'u',
          password: 'p',
          httpClient: MockClient((request) async {
            requests.add(request.url);
            return answer();
          }),
        );

    http.Response ok() => http.Response(
      jsonEncode({
        'subsonic-response': {'status': 'ok'},
      }),
      200,
    );

    test(
      'replays offline plays with their original times, oldest first',
      () async {
        final queue = ScrobbleQueue(File('${dir.path}/q.json'));
        final first = DateTime(2026, 1, 1, 8);
        final second = DateTime(2026, 1, 1, 9);
        await queue.add(PendingScrobble('a', first));
        await queue.add(PendingScrobble('b', second));

        await queue.flush(clientWith(ok));

        expect(requests.map((u) => u.queryParameters['id']), ['a', 'b']);
        expect(
          requests.first.queryParameters['time'],
          '${first.millisecondsSinceEpoch}',
        );
        expect(requests.first.queryParameters['submission'], 'true');
        expect(queue.pending, isEmpty);
      },
    );

    test('keeps plays when the server is down, and across restarts', () async {
      final file = File('${dir.path}/q.json');
      final queue = ScrobbleQueue(file);
      await queue.add(PendingScrobble('a', DateTime(2026)));
      await queue.flush(clientWith(() => http.Response('', 503)));
      expect(queue.pending, hasLength(1));

      final reloaded = ScrobbleQueue(file);
      await reloaded.load();
      expect(reloaded.pending.single.songId, 'a');
    });

    test('drops a play the server refuses, then carries on', () async {
      final queue = ScrobbleQueue(File('${dir.path}/q.json'));
      await queue.add(PendingScrobble('gone', DateTime(2026)));
      await queue.add(PendingScrobble('b', DateTime(2026)));
      var call = 0;
      await queue.flush(
        clientWith(() {
          call++;
          return call == 1
              ? http.Response(
                  jsonEncode({
                    'subsonic-response': {
                      'status': 'failed',
                      'error': {'code': 70, 'message': 'not found'},
                    },
                  }),
                  200,
                )
              : ok();
        }),
      );
      expect(queue.pending, isEmpty);
      expect(requests, hasLength(2));
    });
  });

  group('ListeningController', () {
    late Directory dir;
    late _Harness harness;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('listening');
      SharedPreferences.setMockInitialValues({});
      harness = await _Harness.create(dir);
    });
    tearDown(() async {
      harness.dispose();
      dir.deleteSync(recursive: true);
    });

    test('a third full play within the window downloads the song', () async {
      await harness.playFully(song);
      await harness.playFully(song);
      expect(harness.fetcher.fetched, isEmpty);

      await harness.playFully(song);
      await harness.settle();
      expect(harness.fetcher.fetched, ['s1']);
      expect(harness.ledger.isAuto('s1'), isTrue);
    });

    test('plays older than the window do not count', () async {
      await harness.playFully(song);
      await harness.playFully(song);
      harness.now = harness.now.add(kRepeatWindow + const Duration(days: 1));
      await harness.playFully(song);
      await harness.settle();
      expect(harness.fetcher.fetched, isEmpty);
    });

    test('nothing is fetched on mobile data until Wi-Fi returns', () async {
      harness.network.add(const [ConnectivityResult.mobile]);
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(song);
      }
      await harness.settle();
      expect(harness.fetcher.fetched, isEmpty);

      harness.network.add(const [ConnectivityResult.wifi]);
      await harness.settle();
      expect(harness.fetcher.fetched, ['s1']);
    });

    test('a song the user removed is never fetched again', () async {
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(song);
      }
      await harness.settle();
      await harness.downloads.remove(song);
      harness.fetcher.fetched.clear();

      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(song);
      }
      await harness.settle();
      expect(harness.fetcher.fetched, isEmpty);
    });

    test('saving by hand makes a song permanent', () async {
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(song);
      }
      await harness.settle();
      expect(harness.ledger.isAuto('s1'), isTrue);

      harness.downloads.enqueue([song]);
      expect(harness.ledger.isAuto('s1'), isFalse);
    });

    test('going over the cap evicts the least recently played auto song, '
        'and it needs fresh plays to return', () async {
      harness.fetcher.bytes = kAutoDownloadCapBytes ~/ 2 + 1;
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(song);
      }
      await harness.settle();
      harness.now = harness.now.add(const Duration(hours: 1));
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(otherSong);
      }
      await harness.settle();

      expect(harness.downloads.isDownloaded('s1'), isFalse);
      expect(harness.downloads.isDownloaded('s2'), isTrue);
      expect(harness.ledger.isDeclined('s1'), isFalse);
      expect(harness.fetcher.fetched.where((id) => id == 's1'), hasLength(1));
    });

    test('saving by hand during eviction protects the song', () async {
      harness.fetcher.bytes = kAutoDownloadCapBytes ~/ 2 + 1;
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(song);
      }
      await harness.settle();
      harness.downloads.enqueue([song]);
      harness.now = harness.now.add(const Duration(hours: 1));
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(otherSong);
      }
      await harness.settle();
      expect(harness.downloads.isDownloaded('s1'), isTrue);
    });

    test('a manual download is never evicted', () async {
      harness.fetcher.bytes = kAutoDownloadCapBytes + 1;
      harness.downloads.enqueue([song]);
      await harness.settle();
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(otherSong);
      }
      await harness.settle();
      expect(harness.downloads.isDownloaded('s1'), isTrue);
    });

    test('the setting turns automatic downloads off', () async {
      await harness.settings.setAutoDownloadRepeats(false);
      for (var i = 0; i < kRepeatPlays; i++) {
        await harness.playFully(song);
      }
      await harness.settle();
      expect(harness.fetcher.fetched, isEmpty);
    });

    test('a play made offline reaches the server once back online', () async {
      harness.network.add(const [ConnectivityResult.none]);
      await harness.playFully(song);
      await harness.settle();
      expect(harness.scrobbles.pending, hasLength(1));
      expect(harness.submitted, isEmpty);

      harness.network.add(const [ConnectivityResult.wifi]);
      await harness.settle();
      expect(harness.scrobbles.pending, isEmpty);
      expect(harness.submitted, ['s1']);
    });
  });
}

class _FakeFetcher extends FileFetcher {
  _FakeFetcher(this.dir);

  final Directory dir;
  final List<String> fetched = [];
  int bytes = 1000;

  @override
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    CancelToken? cancel,
    void Function(double)? onProgress,
  }) async {
    final id = uri.queryParameters['id']!;
    fetched.add(id);
    final file = File('${base.path}.mp3')..writeAsStringSync('x');
    return FetchedFile(file, bytes);
  }
}

class _Harness {
  _Harness._(
    this.ledger,
    this.settings,
    this.connectivity,
    this.fetcher,
    this.downloads,
    this.scrobbles,
    this.client,
  );

  static Future<_Harness> create(Directory dir) async {
    final prefs = await SharedPreferences.getInstance();
    final ledger = AutoDownloadLedger(prefs);
    final settings = SettingsController(prefs);
    final networkChanges = StreamController<List<ConnectivityResult>>.broadcast(
      sync: true,
    );
    final connectivity = ConnectivityController(
      changes: networkChanges.stream,
      check: () async => const [ConnectivityResult.wifi],
    );
    final fetcher = _FakeFetcher(dir);
    final store = DownloadStore(Directory('${dir.path}/downloads'));
    await store.load();
    final downloads = DownloadManager(
      store: store,
      settings: settings,
      connectivity: connectivity,
      fetcher: fetcher,
      ledger: ledger,
    );
    final scrobbles = ScrobbleQueue(File('${dir.path}/q.json'));
    final submitted = <String>[];
    final client = SubsonicClient(
      baseUrl: 'http://server',
      username: 'u',
      password: 'p',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('scrobble') &&
            request.url.queryParameters['submission'] == 'true') {
          submitted.add(request.url.queryParameters['id']!);
        }
        return http.Response(
          jsonEncode({
            'subsonic-response': {'status': 'ok'},
          }),
          200,
        );
      }),
    );
    final harness = _Harness._(
      ledger,
      settings,
      connectivity,
      fetcher,
      downloads,
      scrobbles,
      client,
    );
    harness.submitted = submitted;
    harness.network = networkChanges;
    harness.history = PlayHistory(
      File('${dir.path}/h.json'),
      now: () => harness.now,
    );
    harness.controller = ListeningController(
      history: harness.history,
      scrobbles: scrobbles,
      ledger: ledger,
      downloads: downloads,
      settings: settings,
      connectivity: connectivity,
      trackChanges: harness.trackChanges,
      currentSong: () => harness.current,
      isPlaying: () => true,
      positions: harness.positions.stream,
      now: () => harness.now,
    );
    downloads.attach(client);
    harness.controller.attach(client);
    return harness;
  }

  final AutoDownloadLedger ledger;
  final SettingsController settings;
  final ConnectivityController connectivity;
  final _FakeFetcher fetcher;
  final DownloadManager downloads;
  final ScrobbleQueue scrobbles;
  final SubsonicClient client;
  late final List<String> submitted;
  late final StreamController<List<ConnectivityResult>> network;
  late final PlayHistory history;
  late final ListeningController controller;
  final trackChanges = ValueNotifier<int>(0);
  final positions = StreamController<Duration>.broadcast();
  Song? current;
  DateTime now = DateTime(2026, 3, 1);

  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> playFully(Song target) async {
    current = null;
    trackChanges.value++;
    current = target;
    trackChanges.value++;
    for (var s = 0; s <= target.durationSeconds; s++) {
      positions.add(Duration(seconds: s));
      await Future<void>.delayed(Duration.zero);
    }
    await settle();
    now = now.add(const Duration(minutes: 5));
  }

  void dispose() {
    controller.dispose();
    downloads.dispose();
    positions.close();
    network.close();
  }
}
