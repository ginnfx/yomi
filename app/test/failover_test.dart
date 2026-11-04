import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/core/listening/scrobble_queue.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/offline/audio_cache.dart';
import 'package:yomi/core/offline/download_store.dart';
import 'package:yomi/core/stall_detector.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/download_manager.dart';
import 'package:yomi/state/player_controller.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/state/settings.dart';

const songs = [
  Song(id: 'a', title: 'A', artist: 'x', album: 'y', durationSeconds: 200),
  Song(id: 'b', title: 'B', artist: 'x', album: 'y', durationSeconds: 200),
];

class FakeAudio implements AudioPlayer {
  final indexes = StreamController<int?>.broadcast(sync: true);
  bool isPlaying = true;
  ProcessingState state = ProcessingState.ready;
  Duration currentPosition = const Duration(seconds: 42);
  List<AudioSource> sources = const [];
  int? loadedIndex;
  Duration? loadedPosition;
  int loads = 0;
  int plays = 0;

  @override
  Stream<int?> get currentIndexStream => indexes.stream;
  @override
  Stream<Duration> get bufferedPositionStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<bool> get shuffleModeEnabledStream => const Stream.empty();
  @override
  Stream<LoopMode> get loopModeStream => const Stream.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  bool get playing => isPlaying;
  @override
  ProcessingState get processingState => state;
  @override
  Duration get position => currentPosition;
  @override
  List<int> get effectiveIndices => const [0, 1];

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    sources = audioSources;
    loadedIndex = initialIndex;
    loadedPosition = initialPosition;
    loads++;
    return null;
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SubsonicClient clientAt(String url) =>
    SubsonicClient(baseUrl: url, username: 'u', password: 'p');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StallDetector', () {
    final start = DateTime(2026);

    test('reports once when the position stops moving', () {
      final detector = StallDetector();
      expect(
        detector.update(isPlaying: true, position: Duration.zero, now: start),
        isFalse,
      );
      expect(
        detector.update(isPlaying: true, position: Duration.zero, now: start),
        isFalse,
      );
      final later = start.add(kStallAfter);
      expect(
        detector.update(isPlaying: true, position: Duration.zero, now: later),
        isTrue,
      );
      expect(
        detector.update(
          isPlaying: true,
          position: Duration.zero,
          now: later.add(const Duration(seconds: 5)),
        ),
        isFalse,
      );
      expect(detector.isStalled, isTrue);
    });

    test('moving audio or a pause is not a stall', () {
      final detector = StallDetector();
      for (var s = 0; s < 30; s++) {
        expect(
          detector.update(
            isPlaying: true,
            position: Duration(seconds: s),
            now: start.add(Duration(seconds: s)),
          ),
          isFalse,
        );
      }
      for (var s = 30; s < 60; s++) {
        expect(
          detector.update(
            isPlaying: false,
            position: const Duration(seconds: 29),
            now: start.add(Duration(seconds: s)),
          ),
          isFalse,
        );
      }
    });

    test('recovers when audio moves again', () {
      final detector = StallDetector();
      detector.update(isPlaying: true, position: Duration.zero, now: start);
      detector.update(
        isPlaying: true,
        position: Duration.zero,
        now: start.add(kStallAfter),
      );
      detector.update(
        isPlaying: true,
        position: const Duration(seconds: 1),
        now: start.add(kStallAfter),
      );
      expect(detector.isStalled, isFalse);
    });
  });

  group('PlayerController moving between servers', () {
    late Directory dir;
    late FakeAudio audio;
    late PlayerController player;
    late DateTime now;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('failover');
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController(
        await SharedPreferences.getInstance(),
      );
      final connectivity = ConnectivityController(
        changes: const Stream.empty(),
        check: () async => const [ConnectivityResult.wifi],
      );
      audio = FakeAudio();
      now = DateTime(2026);
      player = PlayerController(
        audio,
        cache: AudioCache(dir, maxBytes: 1000),
        downloads: DownloadManager(
          store: DownloadStore(Directory('${dir.path}/d')),
          settings: settings,
          connectivity: connectivity,
        ),
        settings: settings,
        connectivity: connectivity,
        now: () => now,
      );
      player.attach(clientAt('http://primary:4533'));
      await player.playQueue(songs);
      audio.loads = 0;
      audio.plays = 0;
    });

    tearDown(() {
      player.dispose();
      dir.deleteSync(recursive: true);
    });

    String urlOf(AudioSource source) =>
        (source as UriAudioSource).uri.toString();

    test('a stalled song resumes on the new server at the same spot', () async {
      audio.state = ProcessingState.buffering;
      player.attach(clientAt('http://backup:4533'));
      await Future<void>.delayed(Duration.zero);

      expect(audio.loads, 1);
      expect(audio.loadedPosition, const Duration(seconds: 42));
      expect(audio.loadedIndex, 0);
      expect(audio.plays, 1);
      expect(urlOf(audio.sources.first), contains('backup'));
    });

    test('music that is flowing waits for the next song', () async {
      player.attach(clientAt('http://primary-again:4533'));
      await Future<void>.delayed(Duration.zero);
      expect(audio.loads, 0);

      audio.indexes.add(1);
      await Future<void>.delayed(Duration.zero);
      expect(audio.loads, 1);
      expect(audio.loadedIndex, 1);
      expect(audio.loadedPosition, Duration.zero);
      expect(urlOf(audio.sources.first), contains('primary-again'));
    });

    test(
      'if the old server dies before the song ends, it switches then',
      () async {
        var stalls = 0;
        player.onStalled = () => stalls++;
        player.attach(clientAt('http://backup:4533'));
        expect(audio.loads, 0);

        player.checkForStall();
        player.checkForStall();
        now = now.add(kStallAfter);
        player.checkForStall();
        await Future<void>.delayed(Duration.zero);

        expect(stalls, 1);
        expect(audio.loads, 1);
        expect(audio.loadedPosition, const Duration(seconds: 42));
      },
    );

    test('the same address changes nothing', () async {
      player.attach(clientAt('http://primary:4533'));
      await Future<void>.delayed(Duration.zero);
      expect(audio.loads, 0);
    });

    test('paused music reloads but does not start playing', () async {
      audio.isPlaying = false;
      player.attach(clientAt('http://backup:4533'));
      await Future<void>.delayed(Duration.zero);
      expect(audio.loads, 1);
      expect(audio.plays, 0);
    });
  });

  group('read-only backup server', () {
    late List<String> requests;

    SubsonicClient client({required bool isReadOnly}) => SubsonicClient(
      baseUrl: 'http://backup',
      username: 'u',
      password: 'p',
      isReadOnly: () => isReadOnly,
      httpClient: MockClient((request) async {
        requests.add(request.url.path);
        return http.Response(
          jsonEncode({
            'subsonic-response': {'status': 'ok'},
          }),
          200,
        );
      }),
    );

    setUp(() => requests = []);

    test('edits are refused before reaching the server', () async {
      final subject = client(isReadOnly: true);
      final edits = <Future<void> Function()>[
        () => subject.star('a'),
        () => subject.unstar('a'),
        () => subject.createPlaylist('p'),
        () => subject.addToPlaylist('p', const ['a']),
        () => subject.removeFromPlaylist('p', const [0]),
        () => subject.renamePlaylist('p', 'n'),
        () => subject.deletePlaylist('p'),
        () => subject.scrobble('a'),
      ];
      for (final edit in edits) {
        await expectLater(
          edit(),
          throwsA(
            isA<SubsonicException>().having(
              (e) => e.kind,
              'kind',
              ErrorKind.readOnly,
            ),
          ),
        );
      }
      expect(requests, isEmpty);
    });

    test('reading still works, and the handoff is skipped quietly', () async {
      final subject = client(isReadOnly: true);
      await subject.ping();
      await subject.savePlayQueue(
        songs: songs,
        index: 0,
        position: Duration.zero,
        deviceId: 'd',
      );
      expect(requests, hasLength(1));
    });

    test(
      'queued plays wait for the main server instead of being lost',
      () async {
        final dir = Directory.systemTemp.createTempSync('ro');
        addTearDown(() => dir.deleteSync(recursive: true));
        final queue = ScrobbleQueue(File('${dir.path}/q.json'));
        await queue.add(PendingScrobble('a', DateTime(2026)));

        await queue.flush(client(isReadOnly: true));
        expect(queue.pending, hasLength(1));

        await queue.flush(client(isReadOnly: false));
        expect(queue.pending, isEmpty);
        expect(requests.single, endsWith('scrobble'));
      },
    );
  });

  group('SessionController and the backup server', () {
    const primary = 'http://100.1.2.3:4533';
    const replica = 'http://100.9.9.9:4533';

    Future<SessionController> start(Set<String> working) async {
      FlutterSecureStorage.setMockInitialValues({
        'server_url': primary,
        'username': 'u',
        'password': 'p',
        'extra_urls': '["$replica"]',
      });
      final session = SessionController(
        probe: (url, user, password) async => working.contains(url),
        urlProbe: (url, user, password) async => ProbeResult(
          url: url,
          isOk: working.contains(url),
          elapsed: Duration.zero,
        ),
        roleProbe: (url, port) async => url == replica,
      );
      await session.restore();
      await session.checkServer();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      addTearDown(session.dispose);
      return session;
    }

    test('fails over to the backup and goes read-only', () async {
      final session = await start({replica});
      expect(session.serverUrl, replica);
      expect(session.isOnReplica, isTrue);
      expect(session.client.isReadOnly, isTrue);
      expect(session.routeLabel, 'Backup server');
    });

    test('returns when the main server answers again', () async {
      final working = {replica};
      final session = await start(working);
      await session.returnToPrimary();
      expect(session.serverUrl, replica);

      working.add(primary);
      await session.returnToPrimary();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.serverUrl, primary);
      expect(session.isOnReplica, isFalse);
      expect(session.client.isReadOnly, isFalse);
    });

    test(
      'an unclear answer does not make the backup look like the main server',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'server_url': replica,
          'username': 'u',
          'password': 'p',
        });
        var answer = true as bool?;
        final session = SessionController(
          probe: (url, user, password) async => true,
          urlProbe: (url, user, password) async =>
              ProbeResult(url: url, isOk: true, elapsed: Duration.zero),
          roleProbe: (url, port) async => answer,
        );
        addTearDown(session.dispose);
        await session.restore();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(session.isOnReplica, isTrue);

        answer = null;
        session.useUrl(replica);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(session.isOnReplica, isTrue);
        expect(session.client.isReadOnly, isTrue);
      },
    );

    test('a healthy main server is never read-only', () async {
      final session = await start({primary});
      expect(session.serverUrl, primary);
      expect(session.isOnReplica, isFalse);
    });
  });
}
