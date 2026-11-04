import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/catalog_cache.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog_store');
    file = File('${dir.path}/account.json');
  });

  tearDown(() => dir.delete(recursive: true));

  CatalogCache open({DateTime Function()? now, int maxEntries = 128}) =>
      CatalogCache(file: file, now: now, maxEntries: maxEntries);

  test('returns nothing for a query it has never seen', () async {
    final cache = open();
    await cache.load();
    expect(cache.peek('getSong', const {'id': '1'}), isNull);
  });

  test('keeps entries across restarts', () async {
    final first = open();
    await first.load();
    first.put('getSong', const {'id': '1'}, const {'title': 'Love'});
    await first.flush();

    final second = open();
    await second.load();
    expect(second.peek('getSong', const {'id': '1'})?.data['title'], 'Love');
  });

  test('a corrupt file starts empty instead of failing', () async {
    await file.writeAsString('{not json');
    final cache = open();
    await cache.load();
    expect(cache.peek('getSong', const {}), isNull);
  });

  test('removing one endpoint leaves the others', () async {
    final cache = open();
    await cache.load();
    cache.put('getPlaylists', const {}, const {'a': 1});
    cache.put('getPlaylist', const {'id': '9'}, const {'b': 2});
    cache.put('getArtists', const {}, const {'c': 3});

    cache.remove(const {'getPlaylists', 'getPlaylist'});

    expect(cache.peek('getPlaylists', const {}), isNull);
    expect(cache.peek('getPlaylist', const {'id': '9'}), isNull);
    expect(cache.peek('getArtists', const {})?.data['c'], 3);
  });

  test('marking stale keeps the data but forces a refresh', () async {
    final cache = open();
    await cache.load();
    cache.put('getArtists', const {}, const {'c': 3});
    expect(cache.peek('getArtists', const {})!.isFresh, isTrue);

    cache.markAllStale();

    final entry = cache.peek('getArtists', const {})!;
    expect(entry.data['c'], 3);
    expect(entry.isFresh, isFalse);
  });

  test('entries go stale after the refresh window', () async {
    var now = DateTime(2026, 11, 5, 12);
    final cache = open(now: () => now);
    await cache.load();
    cache.put('getArtists', const {}, const {'c': 3});

    now = now.add(CatalogCache.freshFor - const Duration(seconds: 1));
    expect(cache.peek('getArtists', const {})!.isFresh, isTrue);

    now = now.add(const Duration(seconds: 2));
    expect(cache.peek('getArtists', const {})!.isFresh, isFalse);
  });

  test('drops the oldest entries past the limit', () async {
    final cache = open(maxEntries: 2);
    await cache.load();
    cache.put('getSong', const {'id': '1'}, const {});
    cache.put('getSong', const {'id': '2'}, const {});
    cache.put('getSong', const {'id': '3'}, const {});

    expect(cache.peek('getSong', const {'id': '1'}), isNull);
    expect(cache.peek('getSong', const {'id': '3'}), isNotNull);
  });

  test('announces updates so screens can show fresh data', () async {
    final cache = open();
    await cache.load();
    final updates = <String>[];
    final subscription = cache.updates.listen(updates.add);

    cache.put('getArtists', const {}, const {'c': 3});
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(updates, ['getArtists']);
  });

  test('clear removes the saved file', () async {
    final cache = open();
    await cache.load();
    cache.put('getArtists', const {}, const {'c': 3});
    await cache.flush();
    expect(file.existsSync(), isTrue);

    await cache.clear();

    expect(file.existsSync(), isFalse);
    expect(cache.peek('getArtists', const {}), isNull);
  });
}
