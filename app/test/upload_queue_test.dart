import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/upload/bulk_upload_api.dart';
import 'package:yomi/core/upload/file_inspector.dart';
import 'package:yomi/core/upload/library_snapshot.dart';
import 'package:yomi/state/upload_queue.dart';

class FakeTransport implements UploadTransport {
  final Set<String> known = {};
  final List<String> uploaded = [];
  Exception? Function(String name)? failPut;
  Exception? checkError;
  int checks = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<Set<String>> check(List<String> hashes) async {
    checks++;
    final error = checkError;
    if (error != null) throw error;
    return hashes.where(known.contains).toSet();
  }

  @override
  Future<PutResult> put(
    File file, {
    required String sha256,
    required String name,
    required void Function(double) onProgress,
  }) async {
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    active--;
    final error = failPut?.call(name);
    if (error != null) throw error;
    onProgress(1);
    uploaded.add(name);
    known.add(sha256);
    return PutResult.stored;
  }
}

void main() {
  late Directory dir;
  late Directory music;
  late FakeTransport transport;

  UploadQueue newQueue({FileInspector? inspector}) => UploadQueue(
    queueFile: File('${dir.path}/state/queue.json'),
    hashCacheFile: File('${dir.path}/state/hashes.json'),
    inspector: inspector,
    retryAfterUnreachable: const Duration(milliseconds: 10),
  );

  File song(String name, String content) {
    final file = File('${music.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return file;
  }

  Future<void> settle(UploadQueue queue) async {
    for (var i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!queue.isRunning && queue.remaining == 0) return;
      if (queue.pause != null && !queue.isRunning) return;
    }
    fail('queue never settled: ${queue.items.map((i) => i.state)}');
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('uploads');
    music = Directory('${dir.path}/music')..createSync();
    transport = FakeTransport();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('uploads every audio file in a folder, ignoring other files', () async {
    song('a.mp3', 'aaa');
    song('nested/b.flac', 'bbb');
    song('cover.jpg', 'img');
    final queue = newQueue()..attach(transport);

    final added = await queue.addFolder(music.path);
    await settle(queue);

    expect(added, 2);
    expect(transport.uploaded.toSet(), {'a.mp3', 'b.flac'});
    queue.dispose();
  });

  test('identical files in one folder are only sent once', () async {
    song('a.mp3', 'same');
    song('copy of a.mp3', 'same');
    final queue = newQueue()..attach(transport);

    await queue.addFolder(music.path);
    await settle(queue);

    expect(transport.uploaded, hasLength(1));
    expect(queue.count(UploadState.duplicate), 1);
    queue.dispose();
  });

  test('a second run over the same folder uploads nothing', () async {
    song('a.mp3', 'aaa');
    song('b.mp3', 'bbb');
    final queue = newQueue()..attach(transport);
    await queue.addFolder(music.path);
    await settle(queue);
    expect(transport.uploaded, hasLength(2));

    queue.clearFinished();
    await queue.addFolder(music.path);
    await settle(queue);

    expect(transport.uploaded, hasLength(2));
    expect(queue.count(UploadState.duplicate), 2);
    queue.dispose();
  });

  test('never sends more than two at once', () async {
    for (var i = 0; i < 8; i++) {
      song('$i.mp3', 'content $i');
    }
    final queue = newQueue()..attach(transport);
    await queue.addFolder(music.path);
    await settle(queue);
    expect(transport.maxActive, lessThanOrEqualTo(kConcurrentUploads));
    expect(transport.uploaded, hasLength(8));
    queue.dispose();
  });

  test(
    'resumes after the app is killed, without resending finished songs',
    () async {
      song('a.mp3', 'aaa');
      song('b.mp3', 'bbb');
      final first = newQueue()..attach(transport);
      await first.addFolder(music.path);
      await settle(first);
      first.dispose();
      // Pretend the app died with b unfinished by editing what was saved.
      final saved = newQueue();
      await saved.load();
      expect(saved.count(UploadState.done), 2);
      saved.dispose();

      song('c.mp3', 'ccc');
      final second = newQueue();
      await second.load();
      second.attach(transport);
      await second.addFiles(['${music.path}/c.mp3']);
      await settle(second);

      expect(transport.uploaded.where((n) => n == 'a.mp3'), hasLength(1));
      expect(transport.uploaded.where((n) => n == 'c.mp3'), hasLength(1));
      second.dispose();
    },
  );

  test('an item that was uploading when the app died is sent again', () async {
    final file = song('a.mp3', 'aaa');
    final facts = await inspectFile(file.path);
    File('${dir.path}/state/queue.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '[${_itemJson(file.path, 'uploading', facts.sha256)}]',
      );
    final queue = newQueue();
    await queue.load();
    queue.attach(transport);
    await settle(queue);
    expect(transport.uploaded, ['a.mp3']);
    queue.dispose();
  });

  test('re-running does not read files again when nothing changed', () async {
    song('a.mp3', 'aaa');
    var inspections = 0;
    Future<FileFacts> counting(String path) {
      inspections++;
      return inspectFile(path);
    }

    final queue = newQueue(inspector: counting)..attach(transport);
    await queue.addFolder(music.path);
    await settle(queue);
    queue.clearFinished();
    await queue.addFolder(music.path);
    await settle(queue);

    expect(inspections, 1);
    queue.dispose();
  });

  group('likely duplicates', () {
    FileFacts tagged(String path) => FileFacts(
      sha256: path.hashCode.toRadixString(16).padLeft(64, '0'),
      artist: 'Daft Punk',
      title: 'One More Time',
      durationSeconds: 320,
    );

    UploadQueue withLibrary(int durationSeconds) =>
        newQueue(inspector: (path) async => tagged(path))..attach(
          transport,
          loadSnapshot: () async => LibrarySnapshot([
            Song(
              id: '1',
              title: 'one more time!',
              artist: 'DAFT PUNK',
              album: 'x',
              durationSeconds: durationSeconds,
            ),
          ]),
        );

    test('wait for a decision instead of uploading', () async {
      song('a.mp3', 'aaa');
      final queue = withLibrary(321);
      await queue.addFolder(music.path);
      await settle(queue);
      expect(queue.count(UploadState.likelyDuplicate), 1);
      expect(transport.uploaded, isEmpty);
      queue.dispose();
    });

    test('a different length is treated as a different recording', () async {
      song('a.mp3', 'aaa');
      final queue = withLibrary(400);
      await queue.addFolder(music.path);
      await settle(queue);
      expect(transport.uploaded, ['a.mp3']);
      queue.dispose();
    });

    test('"upload anyway" sends it, and "skip" leaves it', () async {
      song('a.mp3', 'aaa');
      song('b.mp3', 'bbb');
      final queue = withLibrary(320);
      await queue.addFolder(music.path);
      await settle(queue);

      queue.uploadAnyway('${music.path}/a.mp3');
      queue.skipLikely('${music.path}/b.mp3');
      await settle(queue);

      expect(transport.uploaded, ['a.mp3']);
      expect(queue.count(UploadState.skipped), 1);
      queue.dispose();
    });

    test('untagged files are never called duplicates', () {
      final snapshot = LibrarySnapshot(const []);
      snapshot.add('Unknown artist', 'Song', 100);
      expect(snapshot.hasLikelyMatch(null, 'Song', 100), isFalse);
      expect(snapshot.hasLikelyMatch('Unknown artist', 'Song', 0), isFalse);
      expect(snapshot.hasLikelyMatch('...', '!!!', 100), isFalse);
    });
  });

  group('when things go wrong', () {
    test('waits for a busy server, then finishes', () async {
      song('a.mp3', 'aaa');
      var busy = true;
      transport.failPut = (_) {
        if (!busy) return null;
        busy = false;
        return const UploadRetryLater(Duration(milliseconds: 20));
      };
      final queue = newQueue()..attach(transport);
      await queue.addFolder(music.path);
      await settle(queue);
      expect(transport.uploaded, ['a.mp3']);
      expect(queue.count(UploadState.failed), 0);
      queue.dispose();
    });

    test('pauses when the server is gone and resumes by itself', () async {
      song('a.mp3', 'aaa');
      var isDown = true;
      transport.failPut = (_) => isDown ? const UploadUnreachable() : null;
      final queue = newQueue()..attach(transport);
      await queue.addFolder(music.path);
      await settle(queue);
      expect(queue.pause, UploadPause.waitingForServer);
      expect(queue.count(UploadState.failed), 0);

      isDown = false;
      for (var i = 0; i < 200 && transport.uploaded.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(transport.uploaded, ['a.mp3']);
      queue.dispose();
    });

    test('stops and says so when storage is full', () async {
      song('a.mp3', 'aaa');
      transport.failPut = (_) => const UploadStorageFull();
      final queue = newQueue()..attach(transport);
      await queue.addFolder(music.path);
      await settle(queue);
      expect(queue.pause, UploadPause.storageFull);

      transport.failPut = null;
      queue.resume();
      await settle(queue);
      expect(transport.uploaded, ['a.mp3']);
      queue.dispose();
    });

    test('refuses to bulk upload to a server without the new routes', () async {
      song('a.mp3', 'aaa');
      transport.checkError = const UploadRouteMissing();
      final queue = newQueue()..attach(transport);
      await queue.addFolder(music.path);
      await settle(queue);
      expect(queue.pause, UploadPause.serverNeedsUpdate);
      expect(transport.uploaded, isEmpty);
      queue.dispose();
    });

    test('a refused file fails alone and the rest carry on', () async {
      song('bad.mp3', 'bad');
      song('good.mp3', 'good');
      transport.failPut = (name) =>
          name == 'bad.mp3' ? const UploadRejected('not audio') : null;
      final queue = newQueue()..attach(transport);
      await queue.addFolder(music.path);
      await settle(queue);
      expect(transport.uploaded, ['good.mp3']);
      final failed = queue.items.firstWhere(
        (i) => i.state == UploadState.failed,
      );
      expect(failed.error, 'not audio');
      queue.dispose();
    });

    test('a damaged transfer is retried, then fails', () async {
      song('a.mp3', 'aaa');
      transport.failPut = (_) => const UploadCorrupted();
      final queue = newQueue()..attach(transport);
      await queue.addFolder(music.path);
      await settle(queue);
      expect(queue.count(UploadState.failed), 1);

      transport.failPut = null;
      queue.retryFailed();
      await settle(queue);
      expect(transport.uploaded, ['a.mp3']);
      queue.dispose();
    });

    test(
      'a file deleted before its turn fails without stopping the queue',
      () async {
        final doomed = song('gone.mp3', 'x');
        song('kept.mp3', 'y');
        final queue = newQueue();
        await queue.addFolder(music.path);
        doomed.deleteSync();
        queue.attach(transport);
        await settle(queue);
        expect(transport.uploaded, ['kept.mp3']);
        expect(queue.count(UploadState.failed), 1);
        queue.dispose();
      },
    );

    test('a damaged saved queue starts empty', () async {
      File('${dir.path}/state/queue.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('[{"path":');
      final queue = newQueue();
      await queue.load();
      expect(queue.items, isEmpty);
      queue.dispose();
    });
  });

  test('hashes match the standard SHA-256', () async {
    final file = song('a.mp3', 'abc');
    final facts = await inspectFile(file.path);
    expect(
      facts.sha256,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('extension check is case-insensitive', () {
    expect(hasUploadExtension('/a/SONG.MP3'), isTrue);
    expect(hasUploadExtension('/a/cover.jpg'), isFalse);
    expect(hasUploadExtension('/a/noext'), isFalse);
  });
}

String _itemJson(String path, String state, String sha) =>
    '{"path":"$path","name":"a.mp3","state":"$state","facts":{"sha256":"$sha"}}';
