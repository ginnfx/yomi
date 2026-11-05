import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/cover_crop.dart';
import 'package:yomi/core/cover_downloader.dart';
import 'package:yomi/core/cover_prefiller.dart';
import 'package:yomi/core/cover_sizes.dart';
import 'package:yomi/core/models.dart';

final Uint8List _bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF]);

class _FakeSource implements CoverSource {
  final Set<String> stored = {};
  final Set<String> inOlderStore = {};
  final Set<String> notOnServer = {};
  final Set<String> unreachable = {};
  final List<String> downloads = [];
  final List<String> migrated = [];
  void Function(String key)? onDownload;

  @override
  bool isBusy = false;

  @override
  Future<Set<String>> savedKeys() async => {...stored};

  @override
  Future<Uint8List?> saved(String cacheKey) async {
    if (!inOlderStore.contains(cacheKey)) return null;
    migrated.add(cacheKey);
    stored.add(cacheKey);
    return _bytes;
  }

  @override
  Future<Uint8List> download(String url, String cacheKey) async {
    downloads.add(cacheKey);
    onDownload?.call(cacheKey);
    if (notOnServer.contains(cacheKey)) throw const CoverNotAvailable('test');
    if (unreachable.contains(cacheKey)) throw Exception('no connection');
    stored.add(cacheKey);
    return _bytes;
  }

  @override
  Future<void> forget(String cacheKey) async {}

  @override
  void cancelDownloads() {}
}

Song _song(String id, {String? cover, DateTime? addedAt}) => Song(
  id: id,
  title: id,
  artist: 'artist',
  album: 'album',
  durationSeconds: 100,
  coverArtId: cover ?? 'mf-$id',
  addedAt: addedAt,
);

String _key(String id) => coverCacheKey('mf-$id', smallCoverPx);

void main() {
  late _FakeSource source;
  late List<Song> songs;
  late bool canRun;
  late CoverPrefiller prefiller;

  setUp(() {
    source = _FakeSource();
    songs = [_song('a'), _song('b'), _song('c')];
    canRun = true;
    prefiller = CoverPrefiller(
      source: source,
      songs: () => songs,
      canRun: () => canRun,
      urlFor: (id) => 'http://s/$id',
      gap: Duration.zero,
      busyCheck: const Duration(milliseconds: 1),
    );
  });

  test('saves every song\'s small cover', () async {
    await prefiller.wake();
    expect(source.downloads, unorderedEquals([_key('a'), _key('b'), _key('c')]));
  });

  test('never downloads a cover that is already saved', () async {
    source.stored.addAll([_key('a'), _key('b')]);
    await prefiller.wake();
    expect(source.downloads, [_key('c')]);
  });

  test('moves a cover from the older store instead of downloading it', () async {
    source.stored.addAll([_key('a'), _key('b')]);
    source.inOlderStore.add(_key('c'));
    await prefiller.wake();
    expect(source.migrated, [_key('c')]);
    expect(source.downloads, isEmpty);
  });

  test('fetches one cover per picture when an ID comes in two forms', () async {
    songs = [_song('a', cover: 'mf-a_856ea3607b69e089'), _song('a')];
    await prefiller.wake();
    expect(source.downloads, [_key('a')]);
  });

  test('skips songs with no cover ID', () async {
    songs = [
      Song(id: 'x', title: 'x', artist: 'y', album: 'z', durationSeconds: 1),
      _song('a'),
    ];
    await prefiller.wake();
    expect(source.downloads, [_key('a')]);
  });

  test('newest songs go first', () async {
    songs = [
      _song('old', addedAt: DateTime(2020)),
      _song('undated'),
      _song('new', addedAt: DateTime(2026)),
    ];
    await prefiller.wake();
    expect(source.downloads, [_key('new'), _key('old'), _key('undated')]);
  });

  test('does nothing when it isn\'t allowed to run', () async {
    canRun = false;
    await prefiller.wake();
    expect(source.downloads, isEmpty);
  });

  test('stops partway when leaving Wi-Fi, and carries on when woken', () async {
    source.onDownload = (key) {
      if (key == _key('a')) canRun = false;
    };
    await prefiller.wake();
    expect(source.downloads, [_key('a')]);

    canRun = true;
    await prefiller.wake();
    expect(source.downloads, [_key('a'), _key('b'), _key('c')]);
  });

  test('gives way while covers on screen are downloading', () async {
    source.isBusy = true;
    final run = prefiller.wake();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(source.downloads, isEmpty);

    source.isBusy = false;
    await run;
    expect(source.downloads, hasLength(3));
  });

  test('waking while already running doesn\'t start a second run', () async {
    await Future.wait([prefiller.wake(), prefiller.wake(), prefiller.wake()]);
    expect(source.downloads, hasLength(3));
  });

  test('a cover the server doesn\'t have isn\'t asked for again', () async {
    source.notOnServer.add(_key('a'));
    await prefiller.wake();
    await prefiller.wake();
    expect(source.downloads.where((k) => k == _key('a')), hasLength(1));
  });

  test('a dropped connection stops the run, and a later wake retries', () async {
    source.unreachable.addAll([_key('a'), _key('b'), _key('c')]);
    await prefiller.wake();
    final tried = source.downloads.length;
    expect(tried, lessThan(3));

    source.unreachable.clear();
    await prefiller.wake();
    expect(source.stored, containsAll([_key('a'), _key('b'), _key('c')]));
  });

  test('carries on by itself after a dropped connection', () async {
    final retrying = CoverPrefiller(
      source: source,
      songs: () => songs,
      canRun: () => canRun,
      urlFor: (id) => 'http://s/$id',
      gap: Duration.zero,
      retryAfter: const Duration(milliseconds: 5),
    );
    source.unreachable.add(_key('a'));
    source.onDownload = (key) {
      if (source.downloads.length > 1) source.unreachable.clear();
    };
    await retrying.wake();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(source.stored, containsAll([_key('a'), _key('b'), _key('c')]));
  });

  test('once finished, waking does no more work until the library changes', () async {
    await prefiller.wake();
    final asked = source.downloads.length;
    source.stored.clear();
    await prefiller.wake();
    expect(source.downloads, hasLength(asked));

    songs = [...songs, _song('d')];
    await prefiller.wake();
    expect(source.downloads, contains(_key('d')));
  });

  test('a library that changes mid-run is picked up afterwards', () async {
    source.onDownload = (key) {
      if (key == _key('a')) songs = [...songs, _song('d')];
    };
    await prefiller.wake();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(source.downloads, contains(_key('d')));
  });

  test('stops when signed out', () async {
    final signedOut = CoverPrefiller(
      source: source,
      songs: () => songs,
      canRun: () => true,
      urlFor: (_) => null,
      gap: Duration.zero,
      busyCheck: const Duration(milliseconds: 1),
    );
    await signedOut.wake();
    expect(source.downloads, isEmpty);
  });
}
