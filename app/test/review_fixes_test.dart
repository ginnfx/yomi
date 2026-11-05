import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/listening/auto_download_ledger.dart';
import 'package:yomi/core/listening/history_api.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/listening/scrobble_queue.dart';
import 'package:yomi/core/messaging/messaging_api.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/offline/audio_cache.dart';
import 'package:yomi/core/offline/download_store.dart';
import 'package:yomi/core/offline/file_fetcher.dart';
import 'package:yomi/core/spotify/spotify_export.dart';
import 'package:yomi/core/spotify/spotify_link.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/download_manager.dart';
import 'package:yomi/state/listening_log.dart';
import 'package:yomi/state/messages_controller.dart';
import 'package:yomi/state/offline_keeper.dart';
import 'package:yomi/state/profile_controller.dart';
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
    return FetchedFile(File('${base.path}.mp3')..writeAsStringSync('x'), 1000);
  }
}

const _imported = Song(
  id: 'imp',
  title: 'I',
  artist: 'A',
  album: 'B',
  durationSeconds: 10,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final opened = <MessagesController>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fixes');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await Future.wait(opened.map((chats) => chats.savedForTest()));
    opened.clear();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('the offline keeper', () {
    Future<
      (OfflineKeeper, DownloadManager, AutoDownloadLedger, SettingsController)
    >
    setUpKeeper({
      required List<Song> Function() imported,
      required bool Function() isReady,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsController(prefs);
      final ledger = AutoDownloadLedger(prefs);
      final connectivity = ConnectivityController(
        changes: const Stream.empty(),
        check: () async => const [ConnectivityResult.wifi],
      );
      await Future<void>.delayed(Duration.zero);
      final store = DownloadStore(Directory('${dir.path}/d'));
      await store.load();
      final downloads = DownloadManager(
        store: store,
        settings: settings,
        connectivity: connectivity,
        fetcher: _Fetcher(),
        ledger: ledger,
      );
      final keeper = OfflineKeeper(
        downloads: downloads,
        ledger: ledger,
        settings: settings,
        connectivity: connectivity,
        history: PlayHistory(File('${dir.path}/h.json')),
        cache: AudioCache(Directory('${dir.path}/c'), maxBytes: 1),
        currentSong: () => null,
        importedSongs: imported,
        isLibraryReady: isReady,
      );
      return (keeper, downloads, ledger, settings);
    }

    SubsonicClient client({void Function()? onPlaylists}) => SubsonicClient(
      baseUrl: 'http://s',
      username: 'me',
      password: 'p',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('getPlaylists')) onPlaylists?.call();
        return http.Response(
          '{"subsonic-response":{"status":"ok","playlists":{"playlist":[]},"playlist":{"entry":[]}}}',
          200,
        );
      }),
    );

    Future<void> settle(DownloadManager downloads) async {
      for (var i = 0; i < 100 && downloads.pendingCount > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test(
      'never removes imported songs before the library has loaded',
      () async {
        var ready = true;
        var songs = const [_imported];
        final (keeper, downloads, ledger, _) = await setUpKeeper(
          imported: () => songs,
          isReady: () => ready,
        );
        downloads.attach(client());
        keeper.attach(client(), 'me');
        await keeper.run();
        await settle(downloads);
        expect(downloads.isDownloaded('imp'), isTrue);

        // A cold start: the library looks empty for a moment.
        ready = false;
        songs = const [];
        await keeper.run();
        await settle(downloads);

        expect(downloads.isDownloaded('imp'), isTrue);
        expect(ledger.isKept('imp'), isTrue);

        // Once it's really loaded and the song has really gone, it can go.
        ready = true;
        await keeper.run();
        await settle(downloads);
        expect(downloads.isDownloaded('imp'), isFalse);
      },
    );

    test(
      'settings that have nothing to do with storage cause no work',
      () async {
        final (keeper, downloads, _, settings) = await setUpKeeper(
          imported: () => const [],
          isReady: () => true,
        );
        var runs = 0;
        final tracked = client(onPlaylists: () => runs++);
        downloads.attach(tracked);
        keeper.attach(tracked, 'me');
        await keeper.run();
        final before = runs;

        await settings.addRecentSearch('hello');
        await settings.setHomeHidden({'discover'});
        await keeper.run();
        final afterExplicit = runs;
        await settings.addRecentSearch('again');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(runs, afterExplicit);
        expect(before, greaterThanOrEqualTo(1));
      },
    );
  });

  group('signing out', () {
    test('a queued scrobble can be forgotten', () async {
      final queue = ScrobbleQueue(File('${dir.path}/s.json'));
      await queue.add(PendingScrobble('s', DateTime(2026)));
      await queue.clear();
      expect(queue.pending, isEmpty);

      final reopened = ScrobbleQueue(File('${dir.path}/s.json'));
      await reopened.load();
      expect(reopened.pending, isEmpty);
    });

    test('the profile is forgotten, including its pictures', () async {
      final profile = await ProfileController.load(Directory('${dir.path}/p'));
      await profile.setNickname('Sam');
      await profile.setBio('Hello');
      final picture = File('${dir.path}/pic.jpg')..writeAsStringSync('x');
      await profile.setAvatar(picture);
      final saved = profile.avatarFile!;
      expect(profile.hasContent, isTrue);

      await profile.clear();

      expect(profile.nickname, isEmpty);
      expect(profile.bio, isEmpty);
      expect(profile.avatarFile, isNull);
      expect(saved.existsSync(), isFalse);
      expect(profile.hasContent, isFalse);
    });

    test('personal choices are forgotten, device choices stay', () async {
      final settings = SettingsController(
        await SharedPreferences.getInstance(),
      );
      await settings.setShareListening(true);
      await settings.addRecentSearch('secret');
      await settings.addLessArtist('Someone');
      await settings.setPlaylistKeepChoice('p1', false);
      await settings.setWifiOnlyDownloads(false);

      await settings.clearPersonal();

      expect(settings.shareListening, isFalse);
      expect(settings.recentSearches, isEmpty);
      expect(settings.lessArtists, isEmpty);
      expect(settings.playlistKeepChoice('p1'), isNull);
      expect(settings.wifiOnlyDownloads, isFalse);
    });
  });

  group('chats', () {
    MessagesController chats(_Chat server) {
      final controller = MessagesController(
        savedChats: dir,
        inboxPollEvery: const Duration(hours: 1),
        threadPollEvery: const Duration(hours: 1),
        me: () => 'me',
      )..attach(server);
      opened.add(controller);
      return controller;
    }

    test('leaving a chat while it opens leaves nothing behind', () async {
      final server = _Chat()..receive('hello');
      final controller = chats(server);
      final opening = controller.openThread('sam');
      controller.closeThread();
      await opening;
      expect(controller.thread, isEmpty);
      controller.dispose();
    });

    test('quickly opening another chat shows that one', () async {
      final server = _Chat()..receive('from sam');
      final controller = chats(server);
      final first = controller.openThread('sam');
      final second = controller.openThread('alex');
      await Future.wait([first, second]);
      expect(controller.thread.where((m) => m.text == 'from sam'), isEmpty);
      controller.dispose();
    });

    test(
      'a message written during startup is not lost to a saved one',
      () async {
        final server = _Chat()..failure = const MessagingOffline('down');
        final first = chats(server);
        await first.sendTo('sam', text: 'one');
        await first.savedForTest();
        first.dispose();

        final second = chats(server);
        await second.sendTo('sam', text: 'two');
        await second.savedForTest();
        server.failure = null;
        await second.flushPending();
        expect(server.sent.map((m) => m.text), unorderedEquals(['one', 'two']));
        second.dispose();
      },
    );

    test('a new reaction on a message already here shows up', () async {
      final server = _Chat()..receive('hello');
      final controller = chats(server);
      await controller.openThread('sam');
      expect(controller.thread.single.reactions, isEmpty);

      server.reactions = {'sam': '🔥'};
      await controller.refreshOpenThread();

      expect(controller.thread.single.reactions['sam'], '🔥');
      controller.dispose();
    });
  });

  group('listening log', () {
    test('plays are sent again if the server lost them', () async {
      final history = PlayHistory(File('${dir.path}/h.json'));
      for (final (i, id) in const ['s', 't'].indexed) {
        await history.record(
          Song(
            id: id,
            title: 'T',
            artist: 'A',
            album: 'B',
            durationSeconds: 100,
          ),
          PlayKind.completed,
          DateTime.now().subtract(Duration(days: 2 - i)),
        );
      }
      final server = <Map<String, Object?>>[];
      final api = HistoryApi(
        serverUrl: 'http://s:1',
        auth: SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'p'),
        port: 4534,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('imported')) {
            return http.Response('{}', 200);
          }
          if (request.method == 'POST') {
            // Like the real server, it ignores plays it already has.
            for (final event
                in ((jsonDecode(request.body) as Map)['events'] as List)
                    .cast<Map<String, Object?>>()) {
              if (!server.any((other) => other['id'] == event['id'])) {
                server.add(event);
              }
            }
            return http.Response('{"added":1}', 200);
          }
          final after = int.parse(request.url.queryParameters['after']!);
          // A position past the end means the log was replaced, so it starts over.
          final start = after > server.length ? 0 : after;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'events': server.skip(start).toList(),
                'next': server.length,
              }),
            ),
            200,
          );
        }),
      );
      final log = ListeningLog(directory: dir, history: history);
      await log.attach(api, 'account');
      await log.sync();
      expect(server, hasLength(2));

      server.clear();
      await log.sync();
      await log.sync();

      expect(server, hasLength(2));
    });

    test(
      'a play in the same millisecond as the last upload still goes',
      () async {
        final history = PlayHistory(File('${dir.path}/h2.json'));
        final at = DateTime.now().subtract(const Duration(days: 1));
        const one = Song(
          id: '1',
          title: 'T',
          artist: 'A',
          album: 'B',
          durationSeconds: 1,
        );
        const two = Song(
          id: '2',
          title: 'T',
          artist: 'A',
          album: 'B',
          durationSeconds: 1,
        );
        await history.record(one, PlayKind.completed, at);
        final ids = <String>{};
        final api = HistoryApi(
          serverUrl: 'http://s:1',
          auth: SubsonicClient(
            baseUrl: 'http://s',
            username: 'u',
            password: 'p',
          ),
          port: 4534,
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('imported')) {
              return http.Response('{}', 200);
            }
            if (request.method == 'POST') {
              for (final event
                  in ((jsonDecode(request.body) as Map)['events'] as List)) {
                ids.add((event as Map)['id'] as String);
              }
              return http.Response('{"added":0}', 200);
            }
            return http.Response('{"events":[],"next":0}', 200);
          }),
        );
        final log = ListeningLog(directory: dir, history: history);
        await log.attach(api, 'account2');
        await log.sync();
        await history.record(two, PlayKind.completed, at);
        await log.sync();
        expect(ids, hasLength(2));
      },
    );
  });

  group('limits on untrusted files', () {
    test('a zip entry far too big to be a real export is skipped', () {
      final archive = Archive();
      final huge = utf8.encode('[]');
      archive.addFile(
        ArchiveFile('Streaming_History_Audio_2021.json', huge.length, huge)
          ..size = maxExportEntryBytes + 1,
      );
      final export = readExport('big.zip', ZipEncoder().encode(archive));
      expect(export.isEmpty, isTrue);
    });

    test('an oversized Spotify page is refused', () async {
      await expectLater(
        fetchSpotifyPlaylist(
          'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
          client: MockClient.streaming((request, _) async {
            return http.StreamedResponse(
              Stream.fromIterable([
                for (var i = 0; i < 20; i++) List.filled(1 << 20, 0x20),
              ]),
              200,
            );
          }),
        ),
        throwsA(isA<SpotifyLinkException>()),
      );
    });
  });
}

class _Chat implements MessagingTransport {
  @override
  Future<void> saveTaste({
    required List<String> topArtists,
    required List<String> topMoods,
  }) async {}

  final List<ChatMessage> messages = [];
  final List<ChatMessage> sent = [];
  Exception? failure;
  Map<String, String> reactions = const {};
  int nextId = 1;

  void receive(String text) => messages.add(
    ChatMessage(
      id: nextId++,
      from: 'sam',
      to: 'me',
      text: text,
      sentAt: DateTime(2026),
    ),
  );

  ChatMessage _current(ChatMessage message) => ChatMessage(
    id: message.id,
    from: message.from,
    to: message.to,
    text: message.text,
    sentAt: message.sentAt,
    reactions: reactions,
  );

  @override
  Future<List<ChatMessage>> thread(
    String withUser, {
    int after = 0,
    int before = 0,
  }) async {
    if (withUser != 'sam') return const [];
    return [
      for (final message in messages)
        if (message.id > after) _current(message),
    ];
  }

  @override
  Future<ChatMessage> send(
    String to, {
    String text = '',
    String? songId,
    String? songTitle,
    String? albumId,
    String? playlistId,
    int? replyTo,
  }) async {
    final error = failure;
    if (error != null) throw error;
    final message = ChatMessage(
      id: nextId++,
      from: 'me',
      to: to,
      text: text,
      sentAt: DateTime(2026),
    );
    sent.add(message);
    return message;
  }

  @override
  Future<List<ChatConversation>> conversations() async => const [];
  @override
  Future<void> react(int messageId, String emoji) async {}
  @override
  Future<int> waitForChange(int revision) async => revision;
  @override
  Future<void> setPlaying({
    String? songId,
    String? title,
    String? artist,
  }) async {}
  @override
  Future<void> markRead(String withUser, int upTo) async {}
  @override
  Future<List<ChatProfile>> profiles() async => const [];
  @override
  Future<void> saveProfile({
    required String displayName,
    required String bio,
  }) async {}
  @override
  Future<void> saveAvatar(File image) async {}
  @override
  Uri avatarUri(String user) => Uri.parse('http://a/$user');
}
