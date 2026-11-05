import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/offline/outbox.dart';
import 'package:yomi/core/offline/storage_plan.dart';
import 'package:yomi/core/subsonic_client.dart';

KeepCandidate _item(
  String id, {
  int bytes = 100,
  bool saved = false,
  DateTime? played,
}) => KeepCandidate(id: id, bytes: bytes, isSaved: saved, lastPlayed: played);

void main() {
  group('storage plan', () {
    test('fetches everything that fits, in order', () {
      final plan = planKeptSongs(
        capBytes: 300,
        wanted: [_item('a'), _item('b'), _item('c')],
      );
      expect(plan.fetch, ['a', 'b', 'c']);
      expect(plan.evict, isEmpty);
      expect(plan.isLimited, isFalse);
    });

    test('stops at the limit and says so', () {
      final plan = planKeptSongs(
        capBytes: 200,
        wanted: [_item('a'), _item('b'), _item('c')],
      );
      expect(plan.fetch, ['a', 'b']);
      expect(plan.isLimited, isTrue);
    });

    test('recently played songs win the space', () {
      final plan = planKeptSongs(
        capBytes: 100,
        wanted: [_item('a'), _item('b', played: DateTime(2026))],
      );
      expect(plan.fetch, ['b']);
    });

    test('makes room by removing what was played longest ago', () {
      final plan = planKeptSongs(
        capBytes: 100,
        wanted: [
          _item('old', saved: true, played: DateTime(2020)),
          _item('new', played: DateTime(2026)),
        ],
      );
      expect(plan.fetch, ['new']);
      expect(plan.evict, ['old']);
    });

    test('never loops: a full device with the same inputs changes nothing', () {
      final first = planKeptSongs(
        capBytes: 100,
        wanted: [_item('a', saved: true), _item('b')],
      );
      expect(first.fetch, isEmpty);
      expect(first.evict, isEmpty);
      expect(first.isLimited, isTrue);
    });

    test('never removes the song playing now', () {
      final plan = planKeptSongs(
        capBytes: 100,
        wanted: [
          _item('playing', saved: true, played: DateTime(2020)),
          _item('new', played: DateTime(2026)),
        ],
        protect: {'playing'},
      );
      expect(plan.evict, isEmpty);
      expect(plan.fetch, isEmpty, reason: 'its space still counts');
      expect(plan.isLimited, isTrue);
    });

    test('removes songs no longer in any kept playlist', () {
      final plan = planKeptSongs(
        capBytes: 100,
        wanted: const [],
        unwanted: ['gone'],
      );
      expect(plan.evict, ['gone']);
    });
  });

  group('outbox', () {
    late Directory dir;
    late File file;
    final requests = <String>[];
    var isDown = false;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('outbox');
      file = File('${dir.path}/outbox.json');
      requests.clear();
      isDown = false;
    });
    tearDown(() => dir.delete(recursive: true));

    SubsonicClient client(Outbox outbox) => SubsonicClient(
      baseUrl: 'http://s',
      username: 'u',
      password: 'p',
      outbox: outbox,
      httpClient: MockClient((request) async {
        if (isDown) throw const SocketException('down');
        requests.add(request.url.pathSegments.last);
        return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'playlist': {
                'entry': [
                  {'id': 'x', 'title': 'x'},
                  {'id': 'song', 'title': 'song'},
                ],
              },
            },
          }),
          200,
        );
      }),
    );

    test('a star made offline succeeds, survives a restart and sends later', () async {
      isDown = true;
      final first = Outbox(file);
      await client(first).star('1');
      expect(first.items, hasLength(1));

      await first.removeFirst();
      await first.add(const OutboxItem('star', {'id': '1'}));
      final second = Outbox(file);
      await second.load();
      expect(second.items.single.endpoint, 'star');

      isDown = false;
      await client(second).flushOutbox();
      expect(requests, ['star']);
      expect(second.items, isEmpty);
    });

    test('sending stops if the server drops again, keeping the order', () async {
      final outbox = Outbox(file);
      await outbox.add(const OutboxItem('star', {'id': '1'}));
      await outbox.add(const OutboxItem('unstar', {'id': '2'}));
      isDown = true;
      await client(outbox).flushOutbox();
      expect(outbox.items, hasLength(2));
      isDown = false;
      await client(outbox).flushOutbox();
      expect(requests, ['star', 'unstar']);
    });

    test('removing a playlist song offline goes by song, not position', () async {
      final outbox = Outbox(file);
      isDown = true;
      const song = Song(
        id: 'song',
        title: 'S',
        artist: 'a',
        album: 'b',
        durationSeconds: 1,
      );
      await client(outbox).removeSongFromPlaylist('9', song, 0);
      expect(outbox.items, hasLength(1));

      isDown = false;
      await client(outbox).flushOutbox();
      expect(requests, ['getPlaylist', 'updatePlaylist']);
      expect(outbox.items, isEmpty);
    });
  });
}
