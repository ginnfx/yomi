import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/offline/audio_cache.dart';
import 'package:yomi/core/offline/audio_files.dart';
import 'package:yomi/core/offline/download_store.dart';
import 'package:yomi/core/offline/file_fetcher.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/download_manager.dart';
import 'package:yomi/state/settings.dart';

/// The start of a real .m4a file followed by [length] - 12 filler bytes.
List<int> _m4a(int length) => [
  0,
  0,
  0,
  0x1c,
  0x66,
  0x74,
  0x79,
  0x70,
  0x4d,
  0x34,
  0x41,
  0x20,
  ...List.filled(length - 12, 1),
];

Song song(String id, {String title = 'T'}) => Song(
  id: id,
  title: title,
  artist: 'A',
  album: 'B',
  durationSeconds: 100,
  coverArtId: 'c$id',
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('yomi_offline');
  });
  tearDown(() => temp.delete(recursive: true));

  group('file type detection', () {
    test('recognises the formats in the library from their first bytes', () {
      expect(sniffExtension(_m4a(20)), 'm4a');
      expect(sniffExtension([0x49, 0x44, 0x33, 4, 0]), 'mp3'); // ID3 tag
      expect(sniffExtension([0xFF, 0xFB, 0x90, 0x00]), 'mp3'); // raw MPEG frame
      expect(sniffExtension([0xFF, 0xF1, 0x50, 0x80]), 'aac'); // raw ADTS
      expect(sniffExtension([0x66, 0x4C, 0x61, 0x43, 0, 0]), 'flac');
      expect(sniffExtension([0x4F, 0x67, 0x67, 0x53, 0, 0]), 'ogg');
      expect(
        sniffExtension([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WAVE'.codeUnits]),
        'wav',
      );
    });

    test('anything else is not audio', () {
      expect(sniffExtension('<html>'.codeUnits), isNull);
      expect(sniffExtension(const []), isNull);
    });
  });

  group('FileFetcher', () {
    late HttpServer server;
    var reply = _Reply.audio(_m4a(5000));

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final r = reply;
        request.response.statusCode = r.status;
        request.response.headers.contentType = ContentType.parse(r.type);
        if (r.promisedLength != null)
          request.response.contentLength = r.promisedLength!;
        request.response.add(r.body);
        try {
          await request.response.close();
        } on Object {
          // client may have hung up (cancel test)
        }
      });
    });
    tearDown(() => server.close(force: true));

    Uri url() => Uri.parse('http://127.0.0.1:${server.port}/x');

    test(
      'saves the file with its real extension and reports progress up to 1.0',
      () async {
        reply = _Reply.audio(_m4a(70000));
        final base = File('${temp.path}/a');
        final progress = <double>[];

        final fetched = await const FileFetcher().fetch(
          url(),
          base,
          onProgress: progress.add,
        );

        expect(fetched.bytes, 70000);
        expect(fetched.file.path, '${base.path}.m4a');
        expect(await fetched.file.length(), 70000);
        expect(progress.last, 1.0);
        expect(File('${base.path}.dl').existsSync(), isFalse);
      },
    );

    test('an mp3 is saved as .mp3, never as a generic extension', () async {
      reply = _Reply.audio([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4]);

      final fetched = await const FileFetcher().fetch(
        url(),
        File('${temp.path}/b'),
      );

      expect(fetched.file.path.endsWith('.mp3'), isTrue);
    });

    test(
      'bytes that are not audio are refused even if the server says audio',
      () async {
        reply = _Reply.audio(List.filled(500, 65));
        final base = File('${temp.path}/junk');

        await expectLater(
          const FileFetcher().fetch(url(), base),
          throwsA(isA<FetchFailed>()),
        );

        expect(findAudioFile(temp, 'junk'), isNull);
        expect(File('${base.path}.dl').existsSync(), isFalse);
      },
    );

    test('a truncated download leaves nothing behind', () async {
      reply = _Reply(200, 'audio/mp4', _m4a(1000), promisedLength: 5000);
      final base = File('${temp.path}/t');

      await expectLater(
        const FileFetcher().fetch(url(), base),
        throwsA(isA<Exception>()),
      );

      expect(findAudioFile(temp, 't'), isNull);
      expect(File('${base.path}.dl').existsSync(), isFalse);
    });

    test('server errors and HTML pages are not saved as songs', () async {
      reply = _Reply(500, 'text/plain', [1, 2, 3]);
      await expectLater(
        const FileFetcher().fetch(url(), File('${temp.path}/c')),
        throwsA(isA<FetchFailed>()),
      );

      reply = _Reply(200, 'text/html', List.filled(100, 60));
      await expectLater(
        const FileFetcher().fetch(url(), File('${temp.path}/c')),
        throwsA(isA<FetchFailed>()),
      );

      expect(findAudioFile(temp, 'c'), isNull);
    });

    test(
      'cancelling stops the transfer and removes the partial file',
      () async {
        reply = _Reply.audio(_m4a(400000));
        final base = File('${temp.path}/d');
        final token = CancelToken()..cancel();

        await expectLater(
          const FileFetcher().fetch(url(), base, cancel: token),
          throwsA(isA<FetchCancelled>()),
        );

        expect(findAudioFile(temp, 'd'), isNull);
        expect(File('${base.path}.dl').existsSync(), isFalse);
      },
    );

    test('fetching again replaces an older copy of a different type', () async {
      File('${temp.path}/e.mp3').writeAsBytesSync([1]);
      reply = _Reply.audio(_m4a(100));

      await const FileFetcher().fetch(url(), File('${temp.path}/e'));

      expect(File('${temp.path}/e.mp3').existsSync(), isFalse);
      expect(File('${temp.path}/e.m4a').existsSync(), isTrue);
    });
  });

  group('DownloadStore', () {
    Future<DownloadStore> openStore() async =>
        DownloadStore(Directory('${temp.path}/dl'))..load();

    Future<FetchedFile> save(DownloadStore store, String id, int bytes) async {
      final file = File('${store.baseFor(id).path}.m4a');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(_m4a(bytes));
      return FetchedFile(file, bytes);
    }

    test(
      'survives a restart and forgets entries whose file vanished',
      () async {
        final store = DownloadStore(Directory('${temp.path}/dl'));
        await store.load();
        await store.add(song('1', title: 'One'), await save(store, '1', 30));
        final two = await save(store, '2', 20);
        await store.add(song('2', title: 'Two'), two);
        await two.file.delete();

        final reopened = DownloadStore(Directory('${temp.path}/dl'));
        await reopened.load();

        expect(reopened.songs.map((s) => s.title), ['One']);
        expect(reopened.totalBytes, 30);
        expect(reopened.contains('2'), isFalse);
        expect(reopened.fileFor('1')!.path.endsWith('.m4a'), isTrue);
      },
    );

    test(
      'old ".audio" downloads are renamed to their real type so they play',
      () async {
        final dir = Directory('${temp.path}/dl')..createSync();
        File('${dir.path}/9.audio').writeAsBytesSync(_m4a(40));
        File('${dir.path}/index.json').writeAsStringSync(
          '{"9":{"song":{"id":"9","title":"Old","artist":"A","album":"B","duration":10},"bytes":40,"savedAt":"2026-01-01T00:00:00.000"}}',
        );

        final store = DownloadStore(dir);
        await store.load();

        expect(store.contains('9'), isTrue);
        expect(store.fileFor('9')!.path.endsWith('9.m4a'), isTrue);
        expect(store.fileFor('9')!.existsSync(), isTrue);
        expect(File('${dir.path}/9.audio').existsSync(), isFalse);
      },
    );

    test('a legacy file that is not audio is dropped instead of kept as a broken download', () async {
      final dir = Directory('${temp.path}/dl')..createSync();
      File('${dir.path}/8.audio').writeAsBytesSync(List.filled(30, 65));
      File('${dir.path}/index.json').writeAsStringSync(
        '{"8":{"song":{"id":"8","title":"Bad","duration":1},"bytes":30,"savedAt":"2026-01-01T00:00:00.000"}}',
      );

      final store = DownloadStore(dir);
      await store.load();

      expect(store.contains('8'), isFalse);
    });

    test('a corrupt index is ignored instead of crashing', () async {
      final dir = Directory('${temp.path}/dl')..createSync();
      File('${dir.path}/index.json').writeAsStringSync('{ not json');
      final store = DownloadStore(dir);

      await store.load();

      expect(store.songs, isEmpty);
    });

    test('remove deletes the file and the entry', () async {
      final store = await openStore();
      await store.add(song('7'), await save(store, '7', 20));
      final file = store.fileFor('7')!;

      await store.remove('7');

      expect(store.contains('7'), isFalse);
      expect(file.existsSync(), isFalse);
    });
  });

  group('AudioCache', () {
    AudioCache newCache(int max) => AudioCache(
      Directory('${temp.path}/cache')..createSync(),
      maxBytes: max,
    );

    File put(AudioCache cache, String id, {int bytes = 100}) =>
        File('${cache.baseFor(id).path}.m4a')..writeAsBytesSync(_m4a(bytes));

    test('finds a cached song whatever its type', () {
      final cache = newCache(1000);
      File('${cache.baseFor('a').path}.mp3').writeAsBytesSync([1]);

      expect(cache.isCached('a'), isTrue);
      expect(cache.find('a')!.path.endsWith('.mp3'), isTrue);
      expect(cache.isCached('zzz'), isFalse);
    });

    test(
      'evicts the least recently used songs first and keeps recent ones',
      () async {
        final cache = newCache(250);
        final old = put(cache, 'old');
        final mid = put(cache, 'mid');
        final fresh = put(cache, 'fresh');
        old.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 3)),
        );
        mid.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 1)),
        );

        final removed = await cache.evict();

        expect(removed, 1);
        expect(old.existsSync(), isFalse);
        expect(mid.existsSync(), isTrue);
        expect(fresh.existsSync(), isTrue);
      },
    );

    test('does nothing while under the limit, and clear empties it', () async {
      final cache = newCache(1000);
      put(cache, 'a', bytes: 20);

      expect(await cache.evict(), 0);
      expect(await cache.sizeBytes(), 20);
      await cache.clear();
      expect(cache.isCached('a'), isFalse);
    });

    test('purging legacy files removes the unplayable .audio copies and leftovers only', () async {
      final cache = newCache(1000);
      File('${cache.directory.path}/old.audio').writeAsBytesSync([1]);
      File('${cache.directory.path}/old.audio.mime').writeAsStringSync('x');
      File('${cache.directory.path}/half.dl').writeAsBytesSync([1]);
      final keep = put(cache, 'good');

      await cache.purgeLegacy();

      expect(File('${cache.directory.path}/old.audio').existsSync(), isFalse);
      expect(
        File('${cache.directory.path}/old.audio.mime').existsSync(),
        isFalse,
      );
      expect(File('${cache.directory.path}/half.dl').existsSync(), isFalse);
      expect(keep.existsSync(), isTrue);
    });

    test('remove drops a bad cached copy', () async {
      final cache = newCache(1000);
      put(cache, 'bad');

      await cache.remove('bad');

      expect(cache.isCached('bad'), isFalse);
    });
  });

  group('DownloadManager', () {
    late StreamController<List<ConnectivityResult>> network;
    late ConnectivityController connectivity;
    late SettingsController settings;
    late DownloadStore store;
    late _FakeFetcher fetcher;
    late DownloadManager manager;

    Future<void> build({
      required List<ConnectivityResult> initial,
      bool wifiOnly = true,
    }) async {
      SharedPreferences.setMockInitialValues({'wifiOnlyDownloads': wifiOnly});
      settings = await SettingsController.load();
      network = StreamController<List<ConnectivityResult>>.broadcast();
      connectivity = ConnectivityController(
        changes: network.stream,
        check: () async => initial,
      );
      await Future<void>.delayed(Duration.zero);
      store = DownloadStore(Directory('${temp.path}/dl'));
      await store.load();
      fetcher = _FakeFetcher();
      manager = DownloadManager(
        store: store,
        settings: settings,
        connectivity: connectivity,
        fetcher: fetcher,
      );
      manager.attach(
        SubsonicClient(baseUrl: 'http://x:4533', username: 'u', password: 'p'),
      );
    }

    /// Gives the manager time to act, then waits for what it started. A fixed wait
    /// alone can be too short on a busy machine.
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (manager.pendingCount > 0 &&
          manager.pausedReason == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('downloads queued songs one at a time and marks them done', () async {
      await build(initial: [ConnectivityResult.wifi]);

      manager.enqueue([song('1'), song('2'), song('3')]);
      await settle();

      expect(fetcher.maxParallel, 1);
      expect(manager.downloadedSongs.length, 3);
      expect(manager.statusOf('2'), DownloadStatus.done);
      expect(manager.localFile('1')!.path.endsWith('.m4a'), isTrue);
    });

    test(
      'waits for Wi-Fi when set to Wi-Fi only, then continues automatically',
      () async {
        await build(initial: [ConnectivityResult.mobile]);

        manager.enqueue([song('1')]);
        await settle();
        expect(manager.statusOf('1'), DownloadStatus.queued);
        expect(manager.pausedReason, 'Waiting for Wi-Fi');

        network.add([ConnectivityResult.wifi]);
        await settle();

        expect(manager.statusOf('1'), DownloadStatus.done);
        expect(manager.pausedReason, isNull);
      },
    );

    test('allows mobile data once the Wi-Fi-only setting is off', () async {
      await build(initial: [ConnectivityResult.mobile], wifiOnly: false);

      manager.enqueue([song('1')]);
      await settle();

      expect(manager.statusOf('1'), DownloadStatus.done);
    });

    test('a failed download is flagged and does not block the rest', () async {
      await build(initial: [ConnectivityResult.wifi]);
      fetcher.failIds.add('bad');

      manager.enqueue([song('bad'), song('ok')]);
      await settle();

      expect(manager.statusOf('bad'), DownloadStatus.failed);
      expect(manager.statusOf('ok'), DownloadStatus.done);
    });

    test(
      'never queues the same song twice and counts saved songs for lists',
      () async {
        await build(initial: [ConnectivityResult.mobile]);

        manager.enqueue([song('1'), song('1')]);

        expect(manager.pendingCount, 1);
        expect(manager.downloadedCountOf([song('1'), song('2')]), 0);
      },
    );

    test('removing a song deletes it from the device', () async {
      await build(initial: [ConnectivityResult.wifi]);
      manager.enqueue([song('1')]);
      await settle();
      final file = manager.localFile('1')!;

      await manager.remove(song('1'));

      expect(manager.isDownloaded('1'), isFalse);
      expect(file.existsSync(), isFalse);
    });
  });
}

class _Reply {
  const _Reply(this.status, this.type, this.body, {this.promisedLength});

  factory _Reply.audio(List<int> body) => _Reply(200, 'audio/mp4', body);

  final int status;
  final String type;
  final List<int> body;
  final int? promisedLength;
}

class _FakeFetcher extends FileFetcher {
  final Set<String> failIds = {};
  int _running = 0;
  int maxParallel = 0;

  @override
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    void Function(double progress)? onProgress,
    CancelToken? cancel,
  }) async {
    _running++;
    if (_running > maxParallel) maxParallel = _running;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (failIds.any((id) => uri.queryParameters['id'] == id))
        throw const FetchFailed('boom');
      await base.parent.create(recursive: true);
      final file = File('${base.path}.m4a');
      await file.writeAsBytes(_m4a(20));
      onProgress?.call(1);
      return FetchedFile(file, 20);
    } finally {
      _running--;
    }
  }
}
