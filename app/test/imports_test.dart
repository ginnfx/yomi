import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/core/spotify/spotify_link.dart';
import 'package:yomi/core/spotify/track_matcher.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/imports_controller.dart';
import 'package:yomi/ui/widgets/youtube_play_button.dart';

const _halo = Song(
  id: 'halo',
  title: 'Halo',
  artist: 'Beyoncé',
  album: 'A',
  durationSeconds: 200,
);

String _embedPage(
  List<Map<String, Object?>> tracks, {
  String name = 'Road trip',
}) =>
    '<html><script id="__NEXT_DATA__" type="application/json">'
    '${jsonEncode({
      'props': {
        'pageProps': {
          'state': {
            'data': {
              'entity': {'name': name, 'trackList': tracks},
            },
          },
        },
      },
    })}</script></html>';

void main() {
  group('Spotify links', () {
    test('accepts real playlist links and URIs', () {
      const id = '37i9dQZF1DXcBWIGoYBM5M';
      for (final link in [
        'https://open.spotify.com/playlist/$id',
        'https://open.spotify.com/playlist/$id?si=abc',
        'https://open.spotify.com/intl-de/playlist/$id',
        'https://open.spotify.com/embed/playlist/$id',
        'spotify:playlist:$id',
        '  https://open.spotify.com/playlist/$id  ',
      ]) {
        expect(spotifyPlaylistId(link), id, reason: link);
      }
    });

    test('refuses anything else, so a link can\'t fetch another site', () {
      const id = '37i9dQZF1DXcBWIGoYBM5M';
      for (final link in [
        '',
        'not a link',
        'http://open.spotify.com/playlist/$id',
        'https://evil.example/playlist/$id',
        'https://open.spotify.com.evil.example/playlist/$id',
        'https://open.spotify.com/album/$id',
        'https://open.spotify.com/playlist/short',
        'https://open.spotify.com/playlist/$id/../../secret',
        'spotify:playlist:../../x',
      ]) {
        expect(spotifyPlaylistId(link), isNull, reason: link);
      }
    });

    test('reads the embed page in order, with durations', () {
      final playlist = parseEmbedPage(
        _embedPage([
          {'title': 'Second', 'subtitle': 'B', 'duration': 180000},
          {'title': 'First', 'subtitle': 'A', 'duration': 200400},
        ]),
      );
      expect(playlist.name, 'Road trip');
      expect(playlist.tracks.map((t) => t.title), ['Second', 'First']);
      expect(playlist.tracks.first.durationSeconds, 180);
    });

    test('a changed or private page gives a clear error', () {
      expect(
        () => parseEmbedPage('<html>nothing</html>'),
        throwsA(isA<SpotifyLinkException>()),
      );
      expect(
        () => parseEmbedPage(_embedPage(const [])),
        throwsA(isA<SpotifyLinkException>()),
      );
      expect(
        () => parseEmbedPage('<script id="__NEXT_DATA__">{"a":1}</script>'),
        throwsA(isA<SpotifyLinkException>()),
      );
    });

    test('warns when it stops at what the page shows', () async {
      Future<LinkedPlaylist> fetch(int count) => fetchSpotifyPlaylist(
        'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
        client: MockClient((request) async {
          expect(request.url.host, 'open.spotify.com');
          return http.Response.bytes(
            utf8.encode(
              _embedPage([
                for (var i = 0; i < count; i++)
                  {'title': 'T$i', 'subtitle': 'A'},
              ]),
            ),
            200,
          );
        }),
      );
      expect((await fetch(20)).mayBeIncomplete, isFalse);
      expect((await fetch(100)).mayBeIncomplete, isTrue);
    });

    test('a private playlist or no connection says so', () async {
      await expectLater(
        fetchSpotifyPlaylist(
          'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
          client: MockClient((_) async => http.Response('', 404)),
        ),
        throwsA(isA<SpotifyLinkException>()),
      );
      await expectLater(
        fetchSpotifyPlaylist(
          'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
          client: MockClient((_) async => throw http.ClientException('down')),
        ),
        throwsA(isA<SpotifyLinkException>()),
      );
      await expectLater(
        fetchSpotifyPlaylist('nonsense'),
        throwsA(isA<SpotifyLinkException>()),
      );
    });
  });

  group('imported playlists', () {
    const missing = ImportEntry(title: 'Halo', artist: 'Beyoncé');
    const other = ImportEntry(title: 'Gone', artist: 'Nobody');

    test('a saved song takes over its place, in order', () {
      const playlist = ImportedPlaylist(
        id: 'p',
        name: 'P',
        entries: [other, missing],
      );
      final next = playlist.rematched(TrackMatcher(const [_halo]));
      expect(next.entries.first.songId, isNull);
      expect(next.entries.last.songId, 'halo');
      expect(next.matchedCount, 1);
    });

    test('nothing changing returns the same playlist', () {
      const playlist = ImportedPlaylist(id: 'p', name: 'P', entries: [other]);
      expect(
        identical(playlist.rematched(TrackMatcher(const [_halo])), playlist),
        isTrue,
      );
    });

    test('a place you emptied on purpose stays empty', () {
      const empty = ImportEntry(
        title: 'Halo',
        artist: 'Beyoncé',
        isUserChoice: true,
      );
      const playlist = ImportedPlaylist(id: 'p', name: 'P', entries: [empty]);
      expect(
        playlist.rematched(TrackMatcher(const [_halo])).entries.single.songId,
        isNull,
      );
    });

    test('the YouTube link is a search, safely encoded', () {
      final uri = youtubeSearchFor('AC/DC', 'Back & Black?');
      expect(uri.host, 'www.youtube.com');
      expect(uri.queryParameters['search_query'], 'AC/DC Back & Black?');
    });
  });

  group('controller', () {
    late Directory dir;
    late List<Map<String, Object?>> server;
    var isDown = false;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('imports');
      server = [];
      isDown = false;
    });
    tearDown(() => dir.delete(recursive: true));

    ImportsApi api() => ImportsApi(
      serverUrl: 'http://server:4533',
      auth: SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'p'),
      port: 4534,
      httpClient: MockClient((request) async {
        if (isDown) throw http.ClientException('down');
        if (request.method == 'GET') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'imports': server})),
            200,
          );
        }
        final id = request.url.pathSegments.last;
        server.removeWhere((p) => p['id'] == id);
        if (request.method == 'PUT') {
          server.add(jsonDecode(request.body) as Map<String, Object?>);
        }
        return http.Response('{"status":"ok"}', 200);
      }),
    );

    ImportsController controller() =>
        ImportsController(file: File('${dir.path}/imports.json'));

    const entries = [ImportEntry(title: 'Halo', artist: 'Beyoncé')];

    test('saves to the server and keeps order', () async {
      final imports = controller();
      await imports.attach(api());
      await imports.add('One', entries);
      await imports.add('Two', entries);
      expect(imports.playlists.map((p) => p.name), ['Two', 'One']);
      expect(server, hasLength(2));
    });

    test('saved while offline, sent once back', () async {
      final imports = controller();
      await imports.attach(api());
      isDown = true;
      await imports.add('One', entries);
      expect(imports.playlists, hasLength(1));
      expect(server, isEmpty);

      final restarted = controller();
      await restarted.load();
      expect(restarted.playlists, hasLength(1));

      isDown = false;
      await restarted.attach(api());
      expect(server, hasLength(1));
      expect(restarted.playlists, hasLength(1));
    });

    test('another device sees it', () async {
      final first = controller();
      await first.attach(api());
      await first.add('One', entries);

      final other = await Directory.systemTemp.createTemp('imports2');
      addTearDown(() => other.delete(recursive: true));
      final second = ImportsController(file: File('${other.path}/i.json'));
      await second.attach(api());
      expect(second.playlists.single.name, 'One');
    });

    test('a new library fills in places and saves them', () async {
      final imports = controller();
      await imports.attach(api());
      await imports.add('One', entries);

      await imports.rematch(const [_halo]);

      expect(imports.playlists.single.entries.single.songId, 'halo');
      expect(server.single.toString(), contains('halo'));
      expect(imports.songsIn(const [_halo]), [_halo]);
    });

    test('deleting removes it everywhere and signing out forgets it', () async {
      final imports = controller();
      await imports.attach(api());
      final playlist = await imports.add('One', entries);
      await imports.remove(playlist.id);
      expect(imports.playlists, isEmpty);
      expect(server, isEmpty);

      await imports.add('Two', entries);
      await imports.attach(null);
      expect(imports.playlists, isEmpty);
      expect(File('${dir.path}/imports.json').existsSync(), isFalse);
    });
  });
}
