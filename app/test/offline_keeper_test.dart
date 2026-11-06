import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/listening/auto_download_ledger.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/offline/audio_cache.dart';
import 'package:yomi/core/offline/download_store.dart';
import 'package:yomi/core/offline/file_fetcher.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/download_manager.dart';
import 'package:yomi/state/offline_keeper.dart';
import 'package:yomi/state/settings.dart';

class _Fetcher extends FileFetcher {
  final fetched = <String>[];

  @override
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    CancelToken? cancel,
    void Function(double)? onProgress,
  }) async {
    fetched.add(uri.queryParameters['id']!);
    final file = File('${base.path}.mp3')..writeAsStringSync('x');
    return FetchedFile(file, 1000);
  }
}

http.Response _ok(Map<String, Object?> body) => http.Response(
  jsonEncode({
    'subsonic-response': {'status': 'ok', ...body},
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _Fetcher fetcher;
  late DownloadManager downloads;
  late SettingsController settings;
  late AutoDownloadLedger ledger;
  late OfflineKeeper keeper;

  final client = SubsonicClient(
    baseUrl: 'http://s',
    username: 'me',
    password: 'p',
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('getPlaylists')) {
        return _ok({
          'playlists': {
            'playlist': [
              {'id': 'mine', 'name': 'Mine', 'owner': 'me', 'songCount': 2},
              {
                'id': 'theirs',
                'name': 'Theirs',
                'owner': 'you',
                'songCount': 1,
              },
            ],
          },
        });
      }
      final id = request.url.queryParameters['id'];
      return _ok({
        'playlist': {
          'entry': id == 'mine'
              ? [
                  {'id': 'a', 'title': 'A', 'duration': 100},
                  {'id': 'b', 'title': 'B', 'duration': 100},
                ]
              : [
                  {'id': 'c', 'title': 'C', 'duration': 100},
                ],
        },
      });
    }),
  );

  Future<void> setUpKeeper({
    required List<ConnectivityResult> network,
    Map<String, Object> prefs = const {},
  }) async {
    dir = await Directory.systemTemp.createTemp('keeper');
    SharedPreferences.setMockInitialValues(prefs);
    final shared = await SharedPreferences.getInstance();
    settings = SettingsController(shared);
    ledger = AutoDownloadLedger(shared);
    final connectivity = ConnectivityController(
      changes: const Stream.empty(),
      check: () async => network,
    );
    await Future<void>.delayed(Duration.zero);
    fetcher = _Fetcher();
    final store = DownloadStore(Directory('${dir.path}/d'));
    await store.load();
    downloads = DownloadManager(
      store: store,
      settings: settings,
      connectivity: connectivity,
      fetcher: fetcher,
      ledger: ledger,
    );
    downloads.attach(client);
    keeper = OfflineKeeper(
      downloads: downloads,
      ledger: ledger,
      settings: settings,
      connectivity: connectivity,
      history: PlayHistory(File('${dir.path}/h.json')),
      cache: AudioCache(Directory('${dir.path}/c'), maxBytes: 1),
      currentSong: () => null,
    );
    addTearDown(() => dir.delete(recursive: true));
  }

  Future<void> settle() async {
    for (var i = 0; i < 100 && downloads.pendingCount > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  const mine = Playlist(
    id: 'mine',
    name: 'Mine',
    songCount: 2,
    durationSeconds: 0,
    owner: 'me',
  );
  const theirs = Playlist(
    id: 'theirs',
    name: 'Theirs',
    songCount: 1,
    durationSeconds: 0,
    owner: 'you',
  );

  test('saves your own playlists on Wi-Fi, not other people\'s', () async {
    await setUpKeeper(network: const [ConnectivityResult.wifi]);
    keeper.attach(client, 'me');
    await keeper.run();
    await settle();

    expect(fetcher.fetched, unorderedEquals(['a', 'b']));
    expect(keeper.isKept(mine), isTrue);
    expect(keeper.isKept(theirs), isFalse);
    expect(keeper.statusOf('mine')?.saved, 2);
    expect(keeper.statusOf('mine')?.isLimited, isFalse);
  });

  test('downloads nothing away from Wi-Fi', () async {
    await setUpKeeper(network: const [ConnectivityResult.mobile]);
    keeper.attach(client, 'me');
    await keeper.run();
    await settle();

    expect(fetcher.fetched, isEmpty);
  });

  test('a per-playlist choice applies, and other accounts\' playlists are never kept', () async {
    await setUpKeeper(
      network: const [ConnectivityResult.wifi],
      prefs: const {'keepPlaylist.mine': false, 'keepPlaylist.theirs': true},
    );
    keeper.attach(client, 'me');
    await keeper.run();
    await settle();

    expect(fetcher.fetched, isEmpty);
  });

  test('a song you removed is not saved again', () async {
    await setUpKeeper(network: const [ConnectivityResult.wifi]);
    keeper.attach(client, 'me');
    await keeper.run();
    await settle();
    await downloads.remove(
      const Song(
        id: 'a',
        title: 'A',
        artist: '',
        album: '',
        durationSeconds: 1,
      ),
    );
    fetcher.fetched.clear();

    await keeper.run();
    await settle();

    expect(fetcher.fetched, isEmpty);
  });

  test('turning it off stops new downloads', () async {
    await setUpKeeper(
      network: const [ConnectivityResult.wifi],
      prefs: const {'keepPlaylistsOffline': false},
    );
    keeper.attach(client, 'me');
    await keeper.run();
    await settle();

    expect(fetcher.fetched, isEmpty);
  });
}
