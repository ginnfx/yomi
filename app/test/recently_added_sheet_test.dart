import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/player_controller.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/ui/widgets/recent_added_sheet.dart';

import 'support/screen_harness.dart';

/// Four albums of six songs, so a three-album page fills more than the sheet.
class _PagedClient extends SubsonicClient {
  _PagedClient()
    : super(baseUrl: 'http://server', username: 'u', password: 'p');

  static const albumCount = 4;
  static const songsPerAlbum = 6;

  final albumOffsets = <int>[];

  @override
  Future<List<Album>> albums(
    String type, {
    int size = 20,
    int offset = 0,
  }) async {
    albumOffsets.add(offset);
    return [
      for (var i = offset; i < offset + size && i < albumCount; i++)
        Album(
          id: 'a$i',
          name: 'Album $i',
          artist: 'Artist $i',
          songCount: songsPerAlbum,
        ),
    ];
  }

  @override
  Future<List<Song>> albumSongs(String albumId) async {
    final album = albumId.substring(1);
    return [
      for (var i = 0; i < songsPerAlbum; i++)
        Song(
          id: 's$album-$i',
          title: 'Album $album song $i',
          artist: 'Artist $album',
          album: 'Album $album',
          durationSeconds: 60,
        ),
    ];
  }
}

class _SheetSession extends FakeSession {
  _SheetSession(this.sheetClient);
  final SubsonicClient sheetClient;
  @override
  SubsonicClient get client => sheetClient;
}

class _RecordingPlayer extends FakePlayer {
  _RecordingPlayer() : super(null);

  final queued = <Song>[];
  int? startedAt;

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    queued
      ..clear()
      ..addAll(songs);
    startedAt = startIndex;
  }
}

void main() {
  Future<(_RecordingPlayer, _PagedClient)> pumpSheet(
    WidgetTester tester, {
    int albumsPerPage = 3,
  }) async {
    final client = _PagedClient();
    final player = _RecordingPlayer();
    await pumpScreen(
      tester,
      Material(
        child: RecentlyAddedSheet(albumsPerPage: albumsPerPage),
      ),
      size: phoneSize,
      extraProviders: [
        ChangeNotifierProvider<SessionController>.value(
          value: _SheetSession(client),
        ),
        ChangeNotifierProvider<PlayerController>.value(value: player),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return (player, client);
  }

  testWidgets('shows the newest albums first and loads more when scrolled', (
    tester,
  ) async {
    final (_, client) = await pumpSheet(tester);

    expect(find.text('Recently added'), findsOneWidget);
    expect(find.text('Album 0 song 0'), findsOneWidget);
    expect(client.albumOffsets, [0]);

    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(client.albumOffsets, [0, 3]);
    expect(find.text('Album 3 song 0'), findsOneWidget);
  });

  testWidgets('tapping a song plays the loaded list from that song', (
    tester,
  ) async {
    final (player, _) = await pumpSheet(tester);

    await tester.tap(find.text('Album 0 song 2'));
    await tester.pump();

    expect(player.queued, hasLength(18));
    expect(player.startedAt, 2);
    expect(player.queued[2].id, 's0-2');
  });

  testWidgets('the ⋯ menu offers the usual song actions', (tester) async {
    await pumpSheet(tester);

    await tester.tap(find.byTooltip('More options').first);
    await tester.pumpAndSettle();

    expect(find.text('Add to playlist'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);
  });

  testWidgets('says so when nothing has been added', (tester) async {
    final client = _EmptyClient();
    await pumpScreen(
      tester,
      const Material(child: RecentlyAddedSheet(albumsPerPage: 3)),
      size: phoneSize,
      extraProviders: [
        ChangeNotifierProvider<SessionController>.value(
          value: _SheetSession(client),
        ),
        ChangeNotifierProvider<PlayerController>.value(value: _RecordingPlayer()),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Nothing new yet'), findsOneWidget);
  });
}

class _EmptyClient extends SubsonicClient {
  _EmptyClient() : super(baseUrl: 'http://server', username: 'u', password: 'p');

  @override
  Future<List<Album>> albums(String type, {int size = 20, int offset = 0}) async =>
      const [];
}
