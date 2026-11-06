import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/youtube/channel_yt_dlp.dart';
import 'package:yomi/core/youtube/yt_dlp.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/listening/scrobble_queue.dart';
import 'package:yomi/core/offline/download_store.dart';
import 'package:yomi/core/offline/outbox.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/core/upload/bulk_upload_api.dart';
import 'package:yomi/state/upload_queue.dart';

class _SlowTransport implements UploadTransport {
  final List<String> uploaded = [];

  @override
  Future<Set<String>> check(List<String> hashes) async => {};

  @override
  Future<PutResult> put(
    File file, {
    required String sha256,
    required String name,
    required void Function(double) onProgress,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    uploaded.add(name);
    return PutResult.stored;
  }
}

String _ok() => jsonEncode({
  'subsonic-response': {'status': 'ok'},
});

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('review_batch'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('files added while an upload is running are still sent', () async {
    final music = Directory('${dir.path}/music')..createSync();
    File('${music.path}/a.mp3').writeAsStringSync('a');
    File('${music.path}/b.mp3').writeAsStringSync('b');
    final queue = UploadQueue(
      queueFile: File('${dir.path}/q.json'),
      hashCacheFile: File('${dir.path}/h.json'),
    );
    final transport = _SlowTransport();
    queue.attach(transport);
    await queue.addFiles(['${music.path}/a.mp3']);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await queue.addFiles(['${music.path}/b.mp3']);
    for (var i = 0; i < 100 && queue.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(queue.isRunning, isFalse);
    expect(transport.uploaded.toSet(), {'a.mp3', 'b.mp3'});
    queue.dispose();
  });

  group('outbox', () {
    SubsonicClient client(Outbox outbox, Future<http.Response> Function() on) =>
        SubsonicClient(
          baseUrl: 'http://s',
          username: 'u',
          password: 'p',
          outbox: outbox,
          httpClient: MockClient((_) => on()),
        );

    test('a server error keeps the saved change', () async {
      final outbox = Outbox(File('${dir.path}/o.json'));
      await outbox.add(const OutboxItem('star', {'id': '1'}));
      await client(
        outbox,
        () async => http.Response('boom', 500),
      ).flushOutbox();
      expect(outbox.items, hasLength(1));
    });

    test('overlapping flushes send each change once', () async {
      final outbox = Outbox(File('${dir.path}/o.json'));
      await outbox.add(const OutboxItem('star', {'id': '1'}));
      var sent = 0;
      final c = client(outbox, () async {
        sent++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return http.Response(_ok(), 200);
      });
      await Future.wait([c.flushOutbox(), c.flushOutbox()]);
      expect(sent, 1);
      expect(outbox.items, isEmpty);
    });

    test('a change queued before load keeps what was saved', () async {
      final file = File('${dir.path}/o.json');
      final seeded = Outbox(file);
      await seeded.add(const OutboxItem('star', {'id': '1'}));
      final fresh = Outbox(file);
      final c = client(fresh, () async => throw const SocketException('down'));
      await c.star('2');
      await fresh.load();
      expect(fresh.items, hasLength(2));
    });
  });

  test('clear during a flush is not undone by the flush', () async {
    final file = File('${dir.path}/s.json');
    final queue = ScrobbleQueue(file);
    await queue.add(PendingScrobble('1', DateTime(2024)));
    await queue.add(PendingScrobble('2', DateTime(2024)));
    final client = SubsonicClient(
      baseUrl: 'http://s',
      username: 'u',
      password: 'p',
      httpClient: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return http.Response(_ok(), 200);
      }),
    );
    final flushing = queue.flush(client);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await queue.clear();
    await flushing;
    expect(queue.pending, isEmpty);
    expect(file.existsSync(), isFalse);
  });

  test('a malformed download entry is skipped, not fatal', () async {
    final dl = Directory('${dir.path}/dl')..createSync();
    File('${dl.path}/index.json').writeAsStringSync(
      jsonEncode({
        'a': {'song': 5},
        'b': {'nonsense': true},
      }),
    );
    final store = DownloadStore(dl);
    await store.load();
    expect(store.songs, isEmpty);
  });

  for (final status in [413, 507]) {
    test('a $status sent before the body is read fails the file, not the server', () async {
      final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      raw.listen((socket) async {
        await socket.first; // the request head
        socket.write(
          'HTTP/1.1 $status X\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}',
        );
        await socket.flush();
        socket.destroy();
      });
      final big = File('${dir.path}/big.mp3')
        ..writeAsBytesSync(List.filled(40 * 1024 * 1024, 1));
      final api = BulkUploadApi(
        serverUrl: 'http://127.0.0.1',
        auth: SubsonicClient(
          baseUrl: 'http://127.0.0.1',
          username: 'u',
          password: 'p',
        ),
        port: raw.port,
      );
      final result = api.put(
        big,
        sha256: 'ab',
        name: 'big.mp3',
        onProgress: (_) {},
      );
      await expectLater(
        result,
        throwsA(anyOf(isA<UploadRejected>(), isA<UploadStorageFull>())),
      );
      await raw.close();
    });
  }

  test('a yt-dlp run that never answers times out', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.yomi.yomi/ytdlp');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => Completer<Object?>().future);
    final ytDlp = ChannelYtDlp(runTimeout: const Duration(milliseconds: 50));
    await expectLater(ytDlp.run(['x']), throwsA(isA<YtDlpException>()));
  });
}
