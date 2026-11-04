import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/catalog_cache.dart';
import 'package:yomi/core/subsonic_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final opened = <CatalogCache>[];
  CatalogCache openCache([String account = 'one']) {
    final cache = CatalogCache(file: File('${dir.path}/$account.json'));
    opened.add(cache);
    return cache;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('client_cache');
  });
  tearDown(() async {
    await Future.wait(opened.map((cache) => cache.flush()));
    opened.clear();
    await dir.delete(recursive: true);
  });

  http.Response ok(Map<String, Object?> body) => http.Response(
    jsonEncode({
      'subsonic-response': {'status': 'ok', ...body},
    }),
    200,
  );

  group('saved data survives what used to wipe it', () {
    late int reads;
    late CatalogCache cache;

    SubsonicClient client({String url = 'http://home.test'}) => SubsonicClient(
      baseUrl: url,
      username: 'one',
      password: 'pw',
      cache: cache,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('getArtists') ||
            request.url.path.endsWith('getPlaylists')) {
          reads++;
          return ok({
            'artists': {'index': []},
            'playlists': {'playlist': []},
          });
        }
        return ok({});
      }),
    );

    setUp(() {
      reads = 0;
      cache = openCache();
    });

    test('a scrobble keeps everything', () async {
      await client().artists();
      await client().scrobble('1', submission: false);
      await client().artists();
      expect(reads, 1);
    });

    test('moving to another address keeps everything', () async {
      await client().artists();
      expect(client(url: 'http://away.test').cachedArtists, isNotNull);
      await client(url: 'http://away.test').artists();
      expect(reads, 1);
    });

    test('a playlist edit only clears playlists', () async {
      await client().artists();
      await client().playlists();
      await client().renamePlaylist('9', 'New');
      expect(client().cachedPlaylists, isNull);
      expect(client().cachedArtists, isNotNull);
    });

    test('a star keeps data on screen but refreshes it', () async {
      await client().artists();
      await client().star('1');
      expect(client().cachedArtists, isNotNull);
      await client().artists();
      await Future<void>.delayed(Duration.zero);
      expect(reads, 2);
    });
  });

  test('reuses persisted search results across clients without network', () async {
    var requests = 0;
    final caches = <CatalogCache>[];
    CatalogCache remember(CatalogCache cache) {
      caches.add(cache);
      return cache;
    }

    SubsonicClient make({String user = 'one'}) => SubsonicClient(
      baseUrl: 'http://music.test',
      username: user,
      password: 'pw',
      cache: remember(openCache(user)),
      httpClient: MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'searchResult3': {
                'song': [
                  {'id': '1', 'title': 'Love'},
                ],
              },
            },
          }),
          200,
        );
      }),
    );
    final timer = Stopwatch()..start();
    await make().search('love');
    final cold = timer.elapsedMicroseconds;
    await caches.last.flush();
    timer.reset();
    expect((await make().search('love')).songs.single.title, 'Love');
    print(
      'Search cache: cold $cold us, warm ${timer.elapsedMicroseconds} us; network requests $requests',
    );
    expect(requests, 1);
    await make(user: 'two').search('love');
    expect(requests, 2);
  });
  test(
    'song count refreshes beyond the loaded page and persists the latest total',
    () async {
      var count = 283;
      var requests = 0;
      final client = SubsonicClient(
        baseUrl: 'http://count.test',
        username: 'one',
        password: 'pw',
        cache: openCache(),
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.path, '/rest/getScanStatus');
          return http.Response(
            jsonEncode({
              'subsonic-response': {
                'status': 'ok',
                'scanStatus': {'count': count, 'scanning': false},
              },
            }),
            200,
          );
        }),
      );
      expect(await client.songCount(), 283);
      count = 284;
      expect(await client.songCount(), 284);
      expect(requests, 2);
      expect(client.cachedSongCount, 284);
    },
  );

  test('concurrent identical requests share one network call', () async {
    var requests = 0;
    final client = SubsonicClient(
      baseUrl: 'http://music.test',
      username: 'one',
      password: 'pw',
      cache: openCache(),
      httpClient: MockClient((_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'artists': {'index': []},
            },
          }),
          200,
        );
      }),
    );
    await Future.wait([client.artists(), client.artists()]);
    expect(requests, 1);
  });
}
