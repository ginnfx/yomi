import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/ai_controller.dart';

const _song = Song(
  id: '1',
  title: 'Halo',
  artist: 'Beyoncé',
  album: 'Fierce',
  durationSeconds: 200,
  genre: 'Pop',
);

void main() {
  late Directory dir;
  late List<http.Request> requests;
  late Map<String, Object?> labels;
  var isDown = false;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ai');
    requests = [];
    isDown = false;
    labels = {
      'available': true,
      'songs': {
        songTagKey('Beyoncé', 'Halo'): {'moods': ['uplifting'], 'energy': 'medium'},
      },
      'artists': {
        'Beyoncé': ['Rihanna'],
      },
    };
  });
  tearDown(() => dir.delete(recursive: true));

  AiApi api() => AiApi(
    serverUrl: 'http://server:4533',
    auth: SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'secret'),
    port: 4534,
    httpClient: MockClient((request) async {
      requests.add(request);
      if (isDown) throw http.ClientException('down');
      if (request.url.path == '/v1/tags') {
        if (request.headers['If-None-Match'] == '"v1"') {
          return http.Response('', 304);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(labels)),
          200,
          headers: {'etag': '"v1"'},
        );
      }
      if (request.url.path == '/v1/search/interpret') {
        return http.Response('{"moods":["sad"],"genres":[],"artists":[]}', 200);
      }
      return http.Response('{"pending":1}', 200);
    }),
  );

  AiController controller() => AiController(file: File('${dir.path}/tags.json'));

  test('labels are found by name, surviving a new song ID', () async {
    final ai = controller()..attach(api());
    await ai.refresh();
    expect(ai.tagFor(_song)?.moods, ['uplifting']);
    expect(
      ai.tagFor(
        const Song(id: 'new', title: 'HALO', artist: 'Beyonce', album: '', durationSeconds: 1),
      )?.energy,
      'medium',
    );
    expect(ai.similarArtists['Beyoncé'], ['Rihanna']);
  });

  test('labels survive a restart and an unchanged server sends nothing new', () async {
    final first = controller()..attach(api());
    await first.refresh();

    final second = controller();
    await second.load();
    expect(second.tagFor(_song)?.moods, ['uplifting']);

    second.attach(api());
    await second.refresh();
    expect(requests.last.headers['If-None-Match'], '"v1"');
    expect(second.tagFor(_song)?.moods, ['uplifting']);
  });

  test('only songs without labels are sent, once for each version of the library', () async {
    final ai = controller()..attach(api());
    await ai.refresh();
    const other = Song(id: '2', title: 'New', artist: 'Someone', album: 'A', durationSeconds: 1);
    final library = [_song, other];
    requests.clear();

    await ai.queueMissing(library);
    await ai.queueMissing(library);

    final queued = requests.where((r) => r.url.path == '/v1/tags/songs').toList();
    expect(queued, hasLength(1));
    final songs = (jsonDecode(queued.single.body) as Map)['songs'] as List;
    expect(songs, hasLength(1));
    expect((songs.single as Map)['title'], 'New');
  });

  test('a server without AI turns everything off quietly', () async {
    labels = {'available': false};
    final ai = controller()..attach(api());
    await ai.refresh();
    requests.clear();

    expect(ai.isAvailable, isFalse);
    await ai.queueMissing(const [_song]);
    expect(await ai.interpret('sad songs'), isNull);
    expect(requests, isEmpty);
  });

  test('failures never reach the screen', () async {
    final ai = controller()..attach(api());
    await ai.refresh();
    isDown = true;
    await ai.refresh();
    expect(await ai.interpret('sad songs'), isNull);
    expect(ai.tagFor(_song)?.moods, ['uplifting']);
  });

  test('signing out forgets labels', () async {
    final ai = controller()..attach(api());
    await ai.refresh();
    ai.attach(null);
    expect(ai.tagFor(_song), isNull);
    expect(ai.isAvailable, isFalse);
  });

  group('filters', () {
    const tag = SongTag(moods: ['sad', 'calm'], energy: 'low');

    test('match on any chosen mood, and energy, genre and artist together', () {
      expect(const SearchFilters(moods: ['sad', 'party']).matches(_song, tag), isTrue);
      expect(const SearchFilters(moods: ['party']).matches(_song, tag), isFalse);
      expect(const SearchFilters(energy: 'low').matches(_song, tag), isTrue);
      expect(const SearchFilters(energy: 'high').matches(_song, tag), isFalse);
      expect(const SearchFilters(genres: ['POP']).matches(_song, tag), isTrue);
      expect(const SearchFilters(artists: ['Rihanna']).matches(_song, tag), isFalse);
    });

    test('an excluded mood rules a song out', () {
      expect(const SearchFilters(excludeMoods: ['sad']).matches(_song, tag), isFalse);
    });

    test('a song with no labels only fails mood and energy filters', () {
      expect(const SearchFilters(moods: ['sad']).matches(_song, null), isFalse);
      expect(const SearchFilters(genres: ['Pop']).matches(_song, null), isTrue);
    });

    test('removing a chip removes only that filter', () {
      const filters = SearchFilters(moods: ['sad', 'calm'], energy: 'low');
      final next = filters.without(mood: 'sad');
      expect(next.moods, ['calm']);
      expect(next.energy, 'low');
      expect(filters.without(energy: true).energy, isNull);
    });
  });
}
