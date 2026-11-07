import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/imports_controller.dart';

class _Server {
  final playlists = <String, Map<String, dynamic>>{};
  Future<void> Function()? beforePut;
  Future<void> Function()? beforeList;
  int puts = 0;

  ImportsApi api() => ImportsApi(
    serverUrl: 'http://server',
    auth: SubsonicClient(
      baseUrl: 'http://server',
      username: 'u',
      password: 'p',
    ),
    port: 4534,
    httpClient: MockClient((request) async {
      if (request.method == 'GET') {
        final snapshot = jsonEncode({'imports': playlists.values.toList()});
        await beforeList?.call();
        return http.Response(snapshot, 200);
      }
      final id = request.url.pathSegments.last;
      if (request.method == 'PUT') {
        puts++;
        await beforePut?.call();
        playlists[id] = jsonDecode(request.body) as Map<String, dynamic>;
      } else if (request.method == 'DELETE') {
        playlists.remove(id);
      }
      return http.Response('{}', 200);
    }),
  );
}

void main() {
  late Directory dir;
  setUp(
    () => dir = Directory.systemTemp.createTempSync('imports-concurrency-'),
  );
  tearDown(() => dir.deleteSync(recursive: true));

  test('overlapping additions retain both songs on the server', () async {
    final server = _Server();
    final imports = ImportsController(file: File('${dir.path}/imports.json'));
    await imports.attach(server.api());
    final playlist = await imports.add('Playlist', []);
    await imports.sync();
    final entered = Completer<void>();
    final release = Completer<void>();
    server.beforePut = () async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    const a = Song(
      id: 'a',
      title: 'A',
      artist: 'Artist',
      album: '',
      durationSeconds: 1,
    );
    const b = Song(
      id: 'b',
      title: 'B',
      artist: 'Artist',
      album: '',
      durationSeconds: 1,
    );
    final addingA = imports.addSong(playlist.id, a);
    await entered.future;
    final addingB = imports.addSong(playlist.id, b);
    release.complete();
    await Future.wait([addingA, addingB]);
    final saved = ImportedPlaylist.fromJson(server.playlists[playlist.id]!);
    expect(saved.entries.map((e) => e.songId), ['a', 'b']);
  });

  test(
    'a local save finishing after logout never uploads to the next account',
    () async {
      final old = _Server();
      final next = _Server();
      final imports = ImportsController(file: File('${dir.path}/imports.json'));
      await imports.attach(old.api());
      final adding = imports.add('Private', []);
      final leaving = imports.attach(null);
      final signingIn = imports.attach(next.api());
      await Future.wait([adding, leaving, signingIn]);
      expect(next.puts, 0);
      expect(imports.playlists, isEmpty);
    },
  );

  test(
    'a stale list response cannot restore a concurrently deleted playlist',
    () async {
      final server = _Server();
      final imports = ImportsController(file: File('${dir.path}/imports.json'));
      await imports.attach(server.api());
      final playlist = await imports.add('Playlist', []);
      await imports.sync();
      final entered = Completer<void>();
      final release = Completer<void>();
      server.beforeList = () async {
        entered.complete();
        await release.future;
      };
      final syncing = imports.sync();
      await entered.future;
      var resurrected = false;
      final removing = imports.remove(playlist.id);
      imports.addListener(() {
        if (imports.playlists.any((p) => p.id == playlist.id))
          resurrected = true;
      });
      release.complete();
      await Future.wait([syncing, removing]);
      expect(resurrected, isFalse);
      expect(imports.playlists, isEmpty);
      expect(server.playlists, isEmpty);
    },
  );
}
