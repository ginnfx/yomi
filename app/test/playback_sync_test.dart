import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/playback_sync_controller.dart';
import 'package:yomi/state/player_controller.dart';
import 'package:yomi/state/settings.dart';

const songs = [
  Song(
    id: 'a',
    title: 'First',
    artist: 'Artist',
    album: 'Album',
    durationSeconds: 100,
  ),
  Song(
    id: 'b',
    title: 'Second',
    artist: 'Artist',
    album: 'Album',
    durationSeconds: 100,
  ),
];

class _Player extends ChangeNotifier implements PlayerController {
  @override
  int userSkips = 0;

  List<Song> _queue = const [];
  int? _index;
  Duration _position = Duration.zero;
  bool _playing = false;
  int loads = 0;
  @override
  String? get error => null;
  @override
  List<Song> get queue => _queue;
  @override
  int? get index => _index;
  @override
  Song? get current => _index == null ? null : _queue[_index!];
  @override
  bool get isPlaying => _playing;
  @override
  bool get isBuffering => false;
  @override
  Duration get position => _position;
  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    loads++;
    _queue = List.unmodifiable(songs);
    _index = startIndex;
    _position = position;
    _playing = autoplay;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> togglePlay() async {
    _playing = !_playing;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Server {
  Map<String, dynamic>? queue;
  int writes = 0;
  bool unavailable = false;
  SubsonicClient client() => SubsonicClient(
    baseUrl: 'http://server:4533',
    username: 'same-account',
    password: 'secret',
    httpClient: MockClient((r) async {
      if (unavailable) return http.Response('offline', 503);
      if (r.url.path.endsWith('/savePlayQueue')) {
        expect(r.method, 'POST');
        expect(r.url.queryParameters.containsKey('t'), isFalse);
        final params = Uri(query: r.body).queryParametersAll;
        expect(params['p'], isNull);
        expect(params['t']!.single, isNotEmpty);
        writes++;
        queue = {
          'current': params['current']!.single,
          'position': int.parse(params['position']!.single),
          'changedBy': params['c']!.single,
          'changed': DateTime.now()
              .toUtc()
              .add(Duration(microseconds: writes))
              .toIso8601String(),
          'entry': params['id']!
              .map((id) => songs.firstWhere((s) => s.id == id).toJson())
              .toList(),
        };
      }
      return http.Response(
        jsonEncode({
          'subsonic-response': {
            'status': 'ok',
            if (queue != null) 'playQueue': queue,
          },
        }),
        200,
      );
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Server server;
  late _Player macPlayer;
  late _Player phonePlayer;
  late PlaybackSyncController mac;
  late PlaybackSyncController phone;
  late SettingsController settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await SettingsController.load();
    server = _Server();
    macPlayer = _Player();
    phonePlayer = _Player();
    mac = PlaybackSyncController(
      player: macPlayer,
      settings: settings,
      deviceId: 'Yomi/macOS/mac',
      pollInterval: const Duration(days: 1),
    );
    phone = PlaybackSyncController(
      player: phonePlayer,
      settings: settings,
      deviceId: 'Yomi/iOS/phone',
      pollInterval: const Duration(days: 1),
    );
    mac.attach(server.client());
    await mac.refresh();
    phone.attach(server.client());
    await phone.refresh();
  });
  tearDown(() {
    mac.dispose();
    phone.dispose();
    macPlayer.dispose();
    phonePlayer.dispose();
    settings.dispose();
  });

  test(
    'offers only another kind of device, never this one or a reinstall',
    () async {
      await macPlayer.playQueue(songs);
      await mac.saveNow();
      await phone.refresh();
      expect(phone.offer?.deviceLabel, 'Mac');
      expect(mac.offer, isNull, reason: 'its own queue is not an offer');

      final reinstalled = PlaybackSyncController(
        player: phonePlayer,
        settings: settings,
        deviceId: 'Yomi/macOS/other-install',
        pollInterval: const Duration(days: 1),
      )..attach(server.client());
      addTearDown(reinstalled.dispose);
      await reinstalled.refresh();
      expect(
        reinstalled.offer,
        isNull,
        reason: 'a Mac with a new id is still the Mac that was playing',
      );
    },
  );

  test('Mac to iPhone handoff preserves queue, current song and position, then pauses the Mac', () async {
    await macPlayer.playQueue(
      songs,
      startIndex: 1,
      position: const Duration(seconds: 42),
    );
    await mac.saveNow();
    await phone.refresh();
    expect(phonePlayer.queue.map((s) => s.id), ['a', 'b']);
    expect(phonePlayer.current!.id, 'b');
    expect(phonePlayer.position, const Duration(seconds: 42));
    expect(phonePlayer.isPlaying, false);
    expect(phone.remote!.deviceLabel, 'Mac');
    await phone.continueHere();
    expect(phonePlayer.isPlaying, true);
    expect(server.queue!['changedBy'], 'Yomi/iOS/phone');
    await mac.refresh();
    expect(macPlayer.isPlaying, false);
    expect(mac.remote!.deviceLabel, 'iPhone');
    final writes = server.writes;
    await mac.saveNow();
    expect(
      server.writes,
      writes,
      reason: 'A device that yielded cannot overwrite the new owner',
    );
  });

  test('changing the queue on a paused device does not stop the one that is playing', () async {
    // Arrange: the phone is playing and the Mac is following along, paused.
    await phonePlayer.playQueue(songs);
    await phone.saveNow();
    await mac.refresh();
    expect(macPlayer.isPlaying, false);
    final writes = server.writes;

    // Act: a song is added on the Mac without pressing play.
    await macPlayer.playQueue([...songs, songs.first], autoplay: false);
    await mac.saveNow();
    await phone.refresh();

    // Assert: nothing was published, the phone plays on, and the Mac keeps its queue.
    expect(server.writes, writes);
    expect(phonePlayer.isPlaying, true);
    await phone.saveNow();
    await mac.refresh();
    expect(macPlayer.queue.length, 3);

    // Pressing play on the Mac is a real takeover.
    await macPlayer.togglePlay();
    await mac.saveNow();
    await phone.refresh();
    expect(phonePlayer.isPlaying, false);
  });

  test(
    'pause and seek publish the latest position and a return handoff works',
    () async {
      await phonePlayer.playQueue(songs);
      await phone.saveNow();
      await phonePlayer.seek(const Duration(seconds: 19));
      await phonePlayer.pause();
      await phone.saveNow();
      await mac.refresh();
      expect(macPlayer.position.inSeconds, 19);
      await mac.continueHere();
      await macPlayer.seek(const Duration(seconds: 27));
      await mac.saveNow();
      await phone.refresh();
      expect(phonePlayer.position.inSeconds, 27);
      expect(phonePlayer.isPlaying, false);
    },
  );

  test(
    'an empty account never clears the remote queue or starts playback',
    () async {
      expect(macPlayer.current, isNull);
      expect(phonePlayer.current, isNull);
      expect(server.writes, 0);
      await mac.saveNow();
      expect(server.writes, 0);
    },
  );

  test(
    'server failure leaves local music playing and retries successfully',
    () async {
      await macPlayer.playQueue(songs);
      server.unavailable = true;
      await mac.saveNow();
      expect(mac.error, isNotNull);
      expect(macPlayer.isPlaying, true);
      server.unavailable = false;
      await mac.saveNow();
      expect(mac.error, isNull);
      expect(server.writes, 1);
    },
  );

  test('turning sync off prevents writes and remote takeovers', () async {
    await settings.setSyncListening(false);
    await macPlayer.playQueue(songs);
    await mac.saveNow();
    await phone.refresh();
    expect(server.writes, 0);
    expect(phonePlayer.current, isNull);
    expect(macPlayer.isPlaying, true);
  });

  test(
    'a background lifecycle change flushes the listening position',
    () async {
      await macPlayer.playQueue(songs, position: const Duration(seconds: 9));
      mac.didChangeAppLifecycleState(AppLifecycleState.paused);
      await mac.saveNow();
      expect(server.queue!['position'], 9000);
    },
  );
  test(
    'reopening the same device restores its saved queue without autoplay',
    () async {
      await macPlayer.playQueue(
        songs,
        startIndex: 1,
        position: const Duration(seconds: 31),
      );
      await mac.saveNow();
      final reopenedPlayer = _Player();
      final reopened = PlaybackSyncController(
        player: reopenedPlayer,
        settings: settings,
        deviceId: 'Yomi/macOS/mac',
        pollInterval: const Duration(days: 1),
      );
      reopened.attach(server.client());
      await reopened.refresh();
      expect(reopenedPlayer.current!.id, 'b');
      expect(reopenedPlayer.position.inSeconds, 31);
      expect(reopenedPlayer.isPlaying, false);
      reopened.dispose();
      reopenedPlayer.dispose();
    },
  );
  test(
    'polling and continuing the same song reuse its loaded audio source',
    () async {
      await phonePlayer.playQueue(songs, position: const Duration(seconds: 9));
      await phone.saveNow();
      await mac.refresh();
      expect(macPlayer.loads, 1);
      await phonePlayer.seek(const Duration(seconds: 14));
      await phone.saveNow();
      await mac.refresh();
      expect(macPlayer.loads, 1);
      expect(macPlayer.position.inSeconds, 14);
      await mac.continueHere();
      expect(macPlayer.loads, 1);
      expect(macPlayer.isPlaying, true);
    },
  );
}
