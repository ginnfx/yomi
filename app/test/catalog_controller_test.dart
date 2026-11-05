import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/catalog_controller.dart';

http.Response _ok(Map<String, Object?> body) => http.Response(
  jsonEncode({
    'subsonic-response': {'status': 'ok', ...body},
  }),
  200,
);

Map<String, Object?> _song(int i) => {
  'id': '$i',
  'title': 'Song $i',
  'artist': 'A',
};

void main() {
  late Directory dir;
  var total = 0;
  var lastScan = 'one';
  var isScanning = false;
  var searches = 0;

  SubsonicClient client({bool fails = false}) => SubsonicClient(
    baseUrl: 'http://music.test',
    username: 'one',
    password: 'pw',
    httpClient: MockClient((request) async {
      if (fails) throw const SocketException('down');
      final path = request.url.path;
      if (path.endsWith('getScanStatus')) {
        return _ok({
          'scanStatus': {
            'count': total,
            'scanning': isScanning,
            'lastScan': lastScan,
          },
        });
      }
      if (path.endsWith('getStarred2')) {
        return _ok({
          'starred2': {
            'song': [
              {'id': '1', 'title': 'Song 1', 'artist': 'A', 'starred': 'x'},
            ],
          },
        });
      }
      searches++;
      final offset = int.parse(request.url.queryParameters['songOffset']!);
      final count = int.parse(request.url.queryParameters['songCount']!);
      final end = (offset + count).clamp(0, total);
      return _ok({
        'searchResult3': {
          'song': [for (var i = offset; i < end; i++) _song(i)],
        },
      });
    }),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog');
    total = 250;
    lastScan = 'one';
    isScanning = false;
    searches = 0;
  });

  tearDown(() => dir.delete(recursive: true));

  test(
    'loads the whole library past the first page, in server order',
    () async {
      final catalog = CatalogController(directory: dir);
      await catalog.attach(client(), 'account');
      await catalog.sync();

      expect(catalog.songs, hasLength(250));
      expect(catalog.songs.last.id, '249');
      expect(catalog.isLoaded, isTrue);
    },
  );

  test('a restart shows saved songs without any network', () async {
    final first = CatalogController(directory: dir);
    await first.attach(client(), 'account');
    await first.sync();

    final second = CatalogController(directory: dir);
    await second.attach(client(fails: true), 'account');

    expect(second.songs, hasLength(250));
    await second.sync();
    expect(
      second.songs,
      hasLength(250),
      reason: 'a failed sync keeps the list',
    );
    expect(second.error, isNotNull);
  });

  test('does not reload while nothing has changed', () async {
    final catalog = CatalogController(directory: dir);
    await catalog.attach(client(), 'account');
    await catalog.sync();
    final before = searches;

    await catalog.sync();

    expect(searches, before);
  });

  test(
    'reloads after a new scan and swaps the list only when finished',
    () async {
      final catalog = CatalogController(directory: dir);
      await catalog.attach(client(), 'account');
      await catalog.sync();

      total = 251;
      lastScan = 'two';
      final sizes = <int>[];
      catalog.addListener(() => sizes.add(catalog.songs.length));
      await catalog.sync();

      expect(catalog.songs, hasLength(251));
      expect(sizes.where((size) => size != 250 && size != 251), isEmpty);
    },
  );

  test('waits for a running scan to finish', () async {
    final catalog = CatalogController(directory: dir);
    await catalog.attach(client(), 'account');
    await catalog.sync();
    final before = searches;

    lastScan = 'two';
    isScanning = true;
    await catalog.sync();
    expect(searches, before);

    isScanning = false;
    await catalog.sync();
    expect(searches, greaterThan(before));
  });

  test('refreshes stars without reloading the library', () async {
    final catalog = CatalogController(directory: dir);
    await catalog.attach(client(), 'account');
    await catalog.sync();

    expect(catalog.songs[1].isStarred, isTrue);
    expect(catalog.songs[2].isStarred, isFalse);
  });

  test('signing out forgets the songs and their file', () async {
    final catalog = CatalogController(directory: dir);
    await catalog.attach(client(), 'account');
    await catalog.sync();
    expect(dir.listSync(), isNotEmpty);

    await catalog.attach(null, null);

    expect(catalog.songs, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test(
    'signing out during a sync neither blocks the next one nor leaves a file',
    () async {
      final gate = Completer<void>();
      var firstSearch = true;
      final slow = SubsonicClient(
        baseUrl: 'http://music.test',
        username: 'one',
        password: 'pw',
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('getScanStatus')) {
            return _ok({
              'scanStatus': {'count': 1, 'scanning': false, 'lastScan': 'x'},
            });
          }
          if (path.endsWith('getStarred2')) return _ok({'starred2': {}});
          if (firstSearch) {
            firstSearch = false;
            await gate.future;
          }
          return _ok({
            'searchResult3': {
              'song': [_song(1)],
            },
          });
        }),
      );
      final catalog = CatalogController(directory: dir);
      await catalog.attach(slow, 'old');
      final running = catalog.sync();
      await Future<void>.delayed(Duration.zero);

      await catalog.attach(null, null);
      gate.complete();
      await running;
      expect(File('${dir.path}/old.json').existsSync(), isFalse);

      await catalog.attach(slow, 'new');
      await catalog.sync();
      expect(catalog.songs, hasLength(1));
      expect(catalog.isSyncing, isFalse);
    },
  );

  test('a different account never sees the previous songs', () async {
    final catalog = CatalogController(directory: dir);
    await catalog.attach(client(), 'account');
    await catalog.sync();

    await catalog.attach(client(), 'other');

    expect(catalog.songs, isEmpty);
  });

  test(
    'a list saved by an older version is fetched again, then not again',
    () async {
      final catalog = CatalogController(directory: dir);
      File('${dir.path}/acct.json').writeAsStringSync(
        jsonEncode({
          'lastScan': 'one',
          'songs': [_song(1)],
        }),
      );
      await catalog.attach(client(), 'acct');
      expect(catalog.songs, hasLength(1));
      await catalog.sync();
      expect(catalog.songs, hasLength(total));
      final first = searches;

      final reopened = CatalogController(directory: dir);
      await reopened.attach(client(), 'acct');
      await reopened.sync();
      expect(searches, first);
    },
  );

  test('knows a cover for an artist without asking the server', () async {
    final catalog = CatalogController(directory: dir);
    File('${dir.path}/acct.json').writeAsStringSync(
      jsonEncode({
        'format': 2,
        'lastScan': 'one',
        'songs': [
          {'id': '1', 'title': 'A', 'artist': 'One'},
          {'id': '2', 'title': 'B', 'artist': 'One', 'coverArt': 'c2'},
          {'id': '3', 'title': 'C', 'artist': 'One', 'coverArt': 'c3'},
        ],
      }),
    );
    await catalog.attach(client(), 'acct');
    expect(catalog.coverForArtist('One'), 'c2');
    expect(catalog.coverForArtist('Nobody'), isNull);
  });
}
