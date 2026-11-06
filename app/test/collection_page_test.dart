import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/taste.dart';
import 'package:yomi/state/ai_controller.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/home_controller.dart';
import 'package:yomi/state/offline_keeper.dart';
import 'package:yomi/state/playlist_covers_controller.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/state/messages_controller.dart';
import 'package:yomi/ui/pages/collection_page.dart';
import 'package:yomi/ui/widgets/song_tile.dart';

import 'support/screen_harness.dart';

const _phone = Size(400, 860);

final _songs = [
  for (var i = 0; i < 6; i++)
    Song(
      id: 'song-$i',
      title: 'Track ${i + 1}',
      artist: 'Castlevania Sound Team',
      album: 'Judgment',
      albumId: 'album-1',
      durationSeconds: 180 + i * 20,
    ),
];

class _FakeKeeper extends ChangeNotifier implements OfflineKeeper {
  @override
  bool isKept(Playlist playlist) => false;
  @override
  PlaylistOfflineStatus? statusOf(String id) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCovers extends ChangeNotifier implements PlaylistCoversController {
  @override
  String? urlFor(String id) => null;
  @override
  bool hasCover(String id) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCatalog extends ChangeNotifier implements CatalogController {
  @override
  List<Song> get songs => _songs;
  @override
  SearchIndex get searchIndex => SearchIndex(_songs);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHome extends ChangeNotifier implements HomeController {
  @override
  TasteProfile get taste => TasteProfile.empty;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAi extends ChangeNotifier implements AiController {
  @override
  Map<String, List<String>> get similarArtists => const {};
  @override
  SongTag? tagFor(Song song) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _album() => CollectionPage(
  title: 'Judgment Original Soundtrack',
  subtitle: 'Castlevania Sound Team',
  kind: CollectionKind.album,
  savedSongs: _songs,
  loadSongs: () async => _songs,
);

void main() {
  setUpAll(loadAppFonts);
  overscrollTests();

  testWidgets('an album reads "Album · 6 songs, 23 min" under its artist', (
    tester,
  ) async {
    await pumpScreen(tester, _album(), size: _phone);

    expect(find.text('Judgment Original Soundtrack'), findsWidgets);
    expect(find.text('Castlevania Sound Team'), findsWidgets);
    expect(find.text('Album · 6 songs, 23 min'), findsOneWidget);
    expect(find.byType(SongTile), findsWidgets);
  });

  testWidgets('a song ⋯ in an album offers no "Remove from this playlist"', (
    tester,
  ) async {
    await pumpScreen(tester, _album(), size: _phone);

    await tester.tap(find.byTooltip('More options').first);
    await settleScreen(tester);

    expect(find.text('Go to album'), findsOneWidget);
    expect(find.text('Remove from this playlist'), findsNothing);
  });

  testWidgets('an album has no Add button', (tester) async {
    await pumpScreen(tester, _album(), size: _phone);

    expect(find.widgetWithText(InkWell, 'Add'), findsNothing);
  });

  testWidgets('a playlist has an Add button that opens the song picker', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      CollectionPage(
        title: 'Road trip',
        subtitle: '',
        kind: CollectionKind.playlist,
        playlist: const Playlist(
          id: 'p1',
          name: 'Road trip',
          songCount: 6,
          durationSeconds: 1000,
        ),
        savedSongs: _songs,
        loadSongs: () async => _songs,
      ),
      size: _phone,
      extraProviders: [
        ChangeNotifierProvider<OfflineKeeper>.value(value: _FakeKeeper()),
        ChangeNotifierProvider<PlaylistCoversController>.value(
          value: _FakeCovers(),
        ),
        ChangeNotifierProvider<CatalogController>.value(value: _FakeCatalog()),
        ChangeNotifierProvider<HomeController>.value(value: _FakeHome()),
        ChangeNotifierProvider<AiController>.value(value: _FakeAi()),
      ],
    );

    await tester.tap(find.widgetWithText(InkWell, 'Add'));
    await settleScreen(tester);

    expect(find.text('Add to Road trip'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  // These reference images were rendered on macOS, like the other screen goldens.
  testWidgets('screenshot', (tester) async {
    await pumpScreen(tester, _album(), size: _phone);

    await expectLater(
      find.byType(CollectionPage),
      matchesGoldenFile('goldens/collection_album.png'),
    );
  }, skip: !Platform.isMacOS);

  testWidgets('screenshot of the song menu', (tester) async {
    await pumpScreen(tester, _album(), size: _phone);
    await tester.tap(find.byTooltip('More options').first);
    await settleScreen(tester);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/song_menu.png'),
    );
  }, skip: !Platform.isMacOS);

  testWidgets('Share opens a card to share and the phone\'s own apps', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      _album(),
      size: _phone,
      extraProviders: [
        ChangeNotifierProvider<MessagesController>(
          create: (_) => MessagesController(),
        ),
      ],
    );
    await tester.tap(find.byTooltip('More options').first);
    await settleScreen(tester);

    await tester.tap(find.text('Share'));
    await settleScreen(tester);

    expect(find.text('Yomi'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Picture'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);
    if (Platform.isMacOS) {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/share_sheet.png'),
      );
    }
  });
}

void overscrollTests() {
  group('overscrollFillHeight', () {
    test('is nothing while the list is not pulled past its top', () {
      expect(overscrollFillHeight(offset: 0, barHeight: 100), 0);
      expect(overscrollFillHeight(offset: 300, barHeight: 100), 0);
    });

    test(
      'covers the bar plus the whole pull, so no gap shows below the bar',
      () {
        expect(overscrollFillHeight(offset: -330, barHeight: 110), 440);
      },
    );
  });
}
