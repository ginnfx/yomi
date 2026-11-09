import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/offline/file_fetcher.dart';
import 'package:yomi/core/offline/audio_cache.dart';
import 'package:yomi/core/offline/download_store.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/download_manager.dart';
import 'package:yomi/state/player_controller.dart';
import 'package:yomi/state/settings.dart';

List<Song> _songs(int count) => [
  for (var i = 0; i < count; i++)
    Song(
      id: 's$i',
      title: 'S$i',
      artist: 'x',
      album: 'y',
      durationSeconds: 200,
    ),
];

class _DownloadFetcher extends FileFetcher {
  @override
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    void Function(double)? onProgress,
    CancelToken? cancel,
  }) async {
    await base.parent.create(recursive: true);
    final file = File('${base.path}.mp3');
    await file.writeAsBytes([73, 68, 51]);
    return FetchedFile(file, 3);
  }
}

class _Audio implements AudioPlayer {
  final indexes = StreamController<int?>.broadcast(sync: true);
  ProcessingState state = ProcessingState.ready;
  bool isPlaying = false;
  bool isShuffled = false;
  LoopMode loop = LoopMode.off;
  Duration currentPosition = Duration.zero;
  List<int>? shuffledOrder;
  List<AudioSource> sources = const [];
  final loads = <int?>[];
  final seeks = <int?>[];
  List<int>? orderDuringLoad;
  Completer<void>? holdLoad;
  Object? loadError;
  int plays = 0;
  int adds = 0;

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
  bool get shuffleModeEnabled => isShuffled;
  @override
  LoopMode get loopMode => loop;
  @override
  List<AudioSource> get audioSources => sources;
  @override
  List<int> get effectiveIndices =>
      shuffledOrder ?? [for (var i = 0; i < sources.length; i++) i];

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    sources = audioSources;
    loads.add(initialIndex);
    shuffleOrder?.shuffle(initialIndex: initialIndex);
    orderDuringLoad = shuffleOrder?.indices.toList();
    final hold = holdLoad;
    if (hold != null) await hold.future;
    final error = loadError;
    if (error != null) throw error;
    return null;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks.add(index);
  }

  @override
  Future<void> insertAudioSource(int index, AudioSource source) async {
    sources = [...sources.take(index), source, ...sources.skip(index)];
  }

  @override
  Future<void> addAudioSources(List<AudioSource> more) async {
    adds += more.length;
    sources = [...sources, ...more];
  }

  @override
  Future<void> play() async {
    plays++;
    isPlaying = true;
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _Audio audio;
  late PlayerController player;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('skip');
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController(await SharedPreferences.getInstance());
    final connectivity = ConnectivityController(
      changes: const Stream.empty(),
      check: () async => const [ConnectivityResult.wifi],
    );
    audio = _Audio();
    player = PlayerController(
      audio,
      cache: AudioCache(dir, maxBytes: 1000),
      downloads: DownloadManager(
        fetcher: _DownloadFetcher(),
        store: DownloadStore(Directory('${dir.path}/d')),
        settings: settings,
        connectivity: connectivity,
      ),
      settings: settings,
      connectivity: connectivity,
    );
    player.attach(
      SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'p'),
    );
    await player.playQueue(_songs(5));
    audio.loads.clear();
  });

  tearDown(() async {
    player.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> saveQueuedSong(int index) async {
    final song = _songs(5)[index];
    final store = player.downloads.store;
    await store.directory.create(recursive: true);
    final file = File('${store.directory.path}/saved-$index.mp3');
    await file.writeAsBytes([73, 68, 51]);
    await store.add(song, FetchedFile(file, 3));
  }

  test(
    'download notifications defer source changes safely across play-next edits',
    () async {
      await player.downloads.store.load();
      player.downloads.attach(
        SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'p'),
      );
      player.downloads.enqueue([_songs(5)[1]]);
      for (
        var attempt = 0;
        attempt < 100 && player.downloads.pendingCount > 0;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(player.downloads.statusOf('s1'), DownloadStatus.done);
      // Completion must not mutate native queue indexes while editing the play queue.
      expect((audio.sources[1] as UriAudioSource).uri.scheme, 'http');
      const next = Song(
        id: 'new',
        title: 'New',
        artist: 'A',
        album: 'B',
        durationSeconds: 10,
      );
      await player.playNext(next);
      await player.next();
      expect(player.current!.id, 'new');
      await player.next();
      expect(player.current!.id, 's1');
      expect((audio.sources[2] as UriAudioSource).uri.scheme, 'file');
      expect(audio.sources.length, player.queue.length);
    },
  );

  test(
    'a newly downloaded queued song loads locally when skipped to',
    () async {
      await saveQueuedSong(1);
      await player.next();
      expect((audio.sources[1] as UriAudioSource).uri.scheme, 'file');
    },
  );

  test(
    'a downloaded shuffled skip stays local and keeps shuffle order',
    () async {
      audio.isShuffled = true;
      audio.shuffledOrder = [0, 2, 1, 4, 3];
      await saveQueuedSong(2);
      await player.next();
      expect((audio.sources[2] as UriAudioSource).uri.scheme, 'file');
      expect(audio.orderDuringLoad, [0, 2, 1, 4, 3]);
    },
  );

  test(
    'automatic advancement reloads a newly downloaded song locally',
    () async {
      audio.isShuffled = true;
      audio.shuffledOrder = [0, 2, 1, 4, 3];
      await saveQueuedSong(2);
      audio.indexes.add(2);
      await Future<void>.delayed(Duration.zero);
      expect((audio.sources[2] as UriAudioSource).uri.scheme, 'file');
      expect(audio.orderDuringLoad, [0, 2, 1, 4, 3]);
    },
  );

  test(
    'next while playing seeks to the next song and updates at once',
    () async {
      await player.next();
      expect(audio.seeks, [1]);
      expect(player.current?.id, 's1');
    },
  );

  test(
    'next while loading reloads at the target instead of being lost',
    () async {
      audio.state = ProcessingState.loading;
      await player.next();
      expect(audio.seeks, isEmpty);
      expect(audio.loads, [1]);
      expect(player.current?.id, 's1');
    },
  );

  test('repeated taps while loading land on the last song tapped', () async {
    audio.state = ProcessingState.loading;
    audio.holdLoad = Completer<void>();
    final first = player.next();
    final second = player.next();
    final third = player.next();
    expect(player.current?.id, 's3');
    audio.holdLoad!.complete();
    await Future.wait([first, second, third]);
    expect(audio.loads.last, 3);
    expect(player.current?.id, 's3');
    expect(player.error, isNull);
  });

  test('a reload keeps playing if it was playing', () async {
    audio.state = ProcessingState.loading;
    audio.isPlaying = true;
    audio.plays = 0;
    await player.next();
    expect(audio.plays, 1);
  });

  test('a skip tapped before playback started still ends up playing', () async {
    audio.isPlaying = false;
    audio.holdLoad = Completer<void>();
    audio.state = ProcessingState.loading;
    audio.plays = 0;
    final start = player.playQueue(_songs(5));
    final skip = player.next();
    audio.holdLoad!.complete();
    await Future.wait([start, skip]);
    expect(audio.plays, greaterThan(0));
    expect(player.current?.id, 's1');
  });

  test('an interrupted load is not reported as a problem', () async {
    audio.loadError = PlayerInterruptedException('replaced');
    await player.playQueue(_songs(2));
    expect(player.error, isNull);
  });

  test('a real load failure is still reported', () async {
    audio.loadError = PlayerException(0, 'bad', 0);
    await player.playQueue(_songs(2));
    expect(player.error, isNotNull);
  });

  test('a replaced load cannot report a failure over the new one', () async {
    audio.holdLoad = Completer<void>();
    audio.loadError = PlayerException(0, 'bad', 0);
    final first = player.playQueue(_songs(2));
    audio.loadError = null;
    final second = player.playQueue(_songs(3));
    audio.loadError = PlayerException(0, 'bad', 0);
    audio.holdLoad!.complete();
    await first;
    audio.loadError = null;
    await second;
    expect(player.queue, hasLength(3));
  });

  test('the old song reporting during a skip does not undo it', () async {
    audio.state = ProcessingState.loading;
    audio.holdLoad = Completer<void>();
    final skip = player.next();
    audio.indexes.add(0);
    expect(player.current?.id, 's1');
    audio.indexes.add(1);
    audio.holdLoad!.complete();
    await skip;
    expect(player.current?.id, 's1');
  });

  test('repeat-one does not trap next or previous', () async {
    audio.loop = LoopMode.one;
    await player.next();
    expect(audio.seeks, [1]);
    await player.previous();
    expect(audio.seeks, [1, 0]);
  });

  test('repeat-all wraps from the last song to the first', () async {
    audio.loop = LoopMode.all;
    audio.state = ProcessingState.ready;
    await player.jumpTo(4);
    audio.indexes.add(4);
    audio.seeks.clear();
    await player.next();
    expect(audio.seeks, [0]);
  });

  test('skips follow the shuffled order', () async {
    audio.isShuffled = true;
    audio.shuffledOrder = [0, 3, 1, 4, 2];
    await player.next();
    expect(audio.seeks, [3]);
    expect(player.current?.id, 's3');
  });

  test('a reload keeps the shuffled order', () async {
    audio.isShuffled = true;
    audio.shuffledOrder = [0, 3, 1, 4, 2];
    audio.state = ProcessingState.loading;
    await player.next();
    expect(audio.loads, [3]);
    expect(audio.orderDuringLoad, [0, 3, 1, 4, 2]);
  });

  test('the last song with nothing to suggest disables next', () async {
    await player.jumpTo(4);
    audio.indexes.add(4);
    audio.seeks.clear();
    expect(player.canSkipNext, isFalse);
    await player.next();
    expect(audio.seeks, isEmpty);
    expect(player.current?.id, 's4');
  });

  test(
    'the last song continues with suggestions when there are some',
    () async {
      await player.jumpTo(4);
      audio.indexes.add(4);
      audio.seeks.clear();
      player.suggestNext = () => [
        const Song(
          id: 'new',
          title: 'N',
          artist: 'x',
          album: 'y',
          durationSeconds: 1,
        ),
        const Song(
          id: 's1',
          title: 'S1',
          artist: 'x',
          album: 'y',
          durationSeconds: 1,
        ),
      ];
      expect(player.canSkipNext, isTrue);
      await player.next();
      expect(player.current?.id, 'new');
      expect(
        player.queue,
        hasLength(6),
        reason: 'songs already queued stay out',
      );
      expect(audio.seeks, [5]);
    },
  );

  test('previous restarts the song after a few seconds', () async {
    audio.currentPosition = const Duration(seconds: 10);
    await player.jumpTo(2);
    audio.indexes.add(2);
    audio.seeks.clear();
    await player.previous();
    expect(audio.seeks, [null]);
    expect(player.current?.id, 's2');
  });

  test('every skip counts as a user action', () async {
    final before = player.userSkips;
    await player.next();
    expect(player.userSkips, before + 1);
  });
}
