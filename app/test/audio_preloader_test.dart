import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/offline/audio_cache.dart';
import 'package:yomi/core/offline/audio_preloader.dart';
import 'package:yomi/core/offline/file_fetcher.dart';
import 'package:yomi/core/subsonic_client.dart';

Song song(String id) => Song(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  durationSeconds: 100,
);

class _Fetcher extends FileFetcher {
  final List<String> requests = [];
  int active = 0;
  int maxActive = 0;
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    void Function(double)? onProgress,
    CancelToken? cancel,
  }) async {
    expect(uri.path, '/rest/download');
    requests.add(uri.queryParameters['id']!);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (gate != null) await gate!.future;
      if (cancel?.isCancelled ?? false) throw const FetchCancelled();
      if (fail) throw const FetchFailed('offline');
      final file = File('${base.path}.mp3');
      await file.writeAsBytes([0x49, 0x44, 0x33, 1, 2, 3]);
      return FetchedFile(file, 6);
    } finally {
      active--;
    }
  }
}

void main() {
  late Directory dir;
  late AudioCache cache;
  late _Fetcher fetcher;
  late AudioPreloader loader;
  final client = SubsonicClient(
    baseUrl: 'http://server:4533',
    username: 'user',
    password: 'secret',
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yomi-preload');
    cache = AudioCache(dir, maxBytes: 1024);
    fetcher = _Fetcher();
    loader = AudioPreloader(cache: cache, fetcher: fetcher);
  });
  tearDown(() async {
    loader.dispose();
    await loader.idle;
    await dir.delete(recursive: true);
  });

  test('warms original files in order with one request at a time', () async {
    loader.plan(client, [song('a'), song('b'), song('a')]);
    await loader.idle;
    expect(fetcher.requests, ['a', 'b']);
    expect(fetcher.maxActive, 1);
    expect(cache.isCached('a'), true);
    loader.plan(client, [song('a'), song('b')]);
    await loader.idle;
    expect(fetcher.requests.length, 2);
  });
  test(
    'cleared or evicted files can be warmed again in the same session',
    () async {
      loader.plan(client, [song('a')]);
      await loader.idle;
      await cache.clear();
      loader.plan(client, [song('a')]);
      await loader.idle;
      expect(fetcher.requests, ['a', 'a']);
      expect(cache.isCached('a'), true);
    },
  );
  test(
    'a changed queue cancels old work and prioritizes the new song',
    () async {
      final gate = Completer<void>();
      fetcher.gate = gate;
      loader.plan(client, [song('a'), song('b')]);
      loader.plan(client, [song('c'), song('d')]);
      gate.complete();
      await loader.idle;
      expect(fetcher.requests, ['a', 'c', 'd']);
      expect(cache.isCached('a'), false);
      expect(fetcher.maxActive, 1);
    },
  );
  test('failed warming backs off without interrupting playback or hammering the server', () async {
    fetcher.fail = true;
    loader.plan(client, [song('a')]);
    await loader.idle;
    loader.plan(client, [song('a')]);
    await loader.idle;
    expect(fetcher.requests, ['a']);
    expect(cache.isCached('a'), false);
  });
  test(
    'stopping prevents an in-flight download from becoming a cached source',
    () async {
      final gate = Completer<void>();
      fetcher.gate = gate;
      loader.plan(client, [song('a'), song('b')]);
      loader.stop();
      gate.complete();
      await loader.idle;
      expect(fetcher.requests, ['a']);
      expect(cache.isCached('a'), false);
    },
  );
  test(
    'eviction protects the playing song even if it is the oldest file',
    () async {
      final a = File('${cache.baseFor('a').path}.mp3');
      final b = File('${cache.baseFor('b').path}.mp3');
      await a.writeAsBytes(List.filled(6, 1));
      await b.writeAsBytes(List.filled(6, 1));
      await a.setLastModified(DateTime(2000));
      await b.setLastModified(DateTime(2001));
      cache.maxBytes = 6;
      await cache.evict(protect: {'a'});
      expect(cache.isCached('a'), true);
      expect(cache.isCached('b'), false);
    },
  );
}
