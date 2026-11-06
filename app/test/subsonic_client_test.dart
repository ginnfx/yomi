import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/app_info.dart';
import 'package:yomi/core/subsonic_client.dart';

SubsonicClient clientReplying(
  Object body, {
  int status = 200,
  void Function(Uri)? onRequest,
}) {
  return SubsonicClient(
    baseUrl: 'http://music.test:4533/',
    username: 'sindre',
    password: 'sesame',
    saltGenerator: () => 'c19b2d',
    httpClient: MockClient((request) async {
      onRequest?.call(request.url);
      return http.Response(
        body is String ? body : jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
}

Map<String, dynamic> ok(Map<String, dynamic> extra) => {
  'subsonic-response': {'status': 'ok', 'version': '1.16.1', ...extra},
};

void main() {
  test('token auth matches the documented Subsonic example and never sends the password', () {
    final params = clientReplying(ok({})).authParams();

    expect(params['t'], '26719a1196d2a940705a59634eb18eab');
    expect(params['s'], 'c19b2d');
    expect(params.containsKey('p'), isFalse);
  });

  test('tells the server which app version and platform is asking', () {
    addTearDown(() => appInfo = const AppInfo());
    appInfo = const AppInfo(version: '9.8.7', platform: 'android');

    expect(clientReplying(ok({})).authParams()['c'], 'Yomi 9.8.7 android');
  });

  test('says just "Yomi" before the version is known', () {
    expect(clientReplying(ok({})).authParams()['c'], 'Yomi');
  });

  test(
    'search returns songs, albums and artists and sends the query',
    () async {
      late Uri seen;
      final client = clientReplying(
        ok({
          'searchResult3': {
            'song': [
              {
                'id': '1',
                'title': 'Weight of the World',
                'artist': 'Okabe',
                'album': 'NieR',
                'duration': 339,
                'coverArt': 'al-1',
              },
            ],
            'album': [
              {'id': 'a1', 'name': 'NieR', 'artist': 'Okabe', 'songCount': 12},
            ],
            'artist': [
              {'id': 'r1', 'name': 'Okabe', 'albumCount': 2},
            ],
          },
        }),
        onRequest: (uri) => seen = uri,
      );

      final results = await client.search(' nier ');

      expect(seen.path, '/rest/search3');
      expect(seen.queryParameters['query'], 'nier');
      expect(results.songs.single.title, 'Weight of the World');
      expect(results.songs.single.duration, const Duration(seconds: 339));
      expect(results.albums.single.songCount, 12);
      expect(results.artists.single.name, 'Okabe');
    },
  );

  test('blank search never hits the network', () async {
    var calls = 0;
    final client = clientReplying(ok({}), onRequest: (_) => calls++);

    final results = await client.search('   ');

    expect(results.isEmpty, isTrue);
    expect(calls, 0);
  });

  test('missing song fields fall back to readable defaults', () async {
    final client = clientReplying(
      ok({
        'randomSongs': {
          'song': [
            {'id': 7},
          ],
        },
      }),
    );

    final songs = await client.randomSongs();

    expect(songs.single.id, '7');
    expect(songs.single.title, 'Unknown title');
    expect(songs.single.artist, 'Unknown artist');
  });

  test('wrong credentials surface as a friendly error', () async {
    final client = clientReplying({
      'subsonic-response': {
        'status': 'failed',
        'error': {'code': 40, 'message': 'Wrong username or password'},
      },
    });

    await expectLater(
      client.ping(),
      throwsA(
        isA<SubsonicException>().having(
          (e) => e.isBadCredentials,
          'isBadCredentials',
          isTrue,
        ),
      ),
    );
  });

  test('a non-Navidrome address is reported clearly', () async {
    final client = clientReplying('<html>router login</html>');

    await expectLater(
      client.ping(),
      throwsA(
        isA<SubsonicException>().having(
          (e) => e.message,
          'message',
          contains('not a Navidrome server'),
        ),
      ),
    );
  });

  test('playlist edits send repeated parameters', () async {
    late Uri seen;
    final client = clientReplying(ok({}), onRequest: (uri) => seen = uri);

    await client.addToPlaylist('p1', ['s1', 's2']);

    expect(seen.queryParametersAll['songIdToAdd'], ['s1', 's2']);
    expect(seen.queryParameters['playlistId'], 'p1');
  });

  test(
    'the full song list pages through search3 with an empty query',
    () async {
      late Uri seen;
      final client = clientReplying(
        ok({
          'searchResult3': {
            'song': [
              {'id': '1', 'title': 'A'},
              {'id': '2', 'title': 'B'},
            ],
          },
        }),
        onRequest: (uri) => seen = uri,
      );

      final songs = await client.songs(offset: 200, count: 100);

      expect(songs.map((s) => s.id), ['1', '2']);
      expect(seen.queryParameters['query'], '');
      expect(seen.queryParameters['songOffset'], '200');
      expect(seen.queryParameters['songCount'], '100');
    },
  );

  test('errors carry a kind so the app can explain them', () async {
    await expectLater(
      clientReplying('<html/>').ping(),
      throwsA(
        isA<SubsonicException>().having(
          (e) => e.kind,
          'kind',
          ErrorKind.notNavidrome,
        ),
      ),
    );
    await expectLater(
      clientReplying({
        'subsonic-response': {
          'status': 'failed',
          'error': {'code': 40, 'message': 'x'},
        },
      }).ping(),
      throwsA(
        isA<SubsonicException>().having(
          (e) => e.kind,
          'kind',
          ErrorKind.badCredentials,
        ),
      ),
    );
    await expectLater(
      clientReplying('boom', status: 503).ping(),
      throwsA(
        isA<SubsonicException>().having(
          (e) => e.kind,
          'kind',
          ErrorKind.server,
        ),
      ),
    );
  });

  test('stream and cover URLs are self-authenticating and respect the base address', () {
    final client = clientReplying(ok({}));

    final stream = client.streamUri('42', maxBitRate: 128);
    final cover = client.coverArtUri('al-9', size: 600);

    expect(stream.host, 'music.test');
    expect(stream.path, '/rest/stream');
    expect(stream.queryParameters['id'], '42');
    expect(stream.queryParameters['maxBitRate'], '128');
    expect(stream.queryParameters['t'], isNotEmpty);
    expect(cover.queryParameters['size'], '600');
  });
}
