import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/subsonic_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('reuses persisted search results across clients without network', () async {
    var requests = 0;
    SubsonicClient make({String user = 'one'}) => SubsonicClient(
      baseUrl: 'http://music.test',
      username: user,
      password: 'pw',
      cacheEnabled: true,
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
        cacheEnabled: true,
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
      expect(await client.cachedSongCount(), 284);
    },
  );

  test('concurrent identical requests share one network call', () async {
    var requests = 0;
    final client = SubsonicClient(
      baseUrl: 'http://music.test',
      username: 'one',
      password: 'pw',
      cacheEnabled: true,
      httpClient: MockClient((_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'randomSongs': {'song': []},
            },
          }),
          200,
        );
      }),
    );
    await Future.wait([client.randomSongs(), client.randomSongs()]);
    expect(requests, 1);
  });
}
