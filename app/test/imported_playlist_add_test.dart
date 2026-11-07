import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/core/taste.dart';
import 'package:yomi/state/ai_controller.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/home_controller.dart';
import 'package:yomi/state/imports_controller.dart';
import 'package:yomi/state/playlist_covers_controller.dart';
import 'package:yomi/ui/imports/imported_playlist_page.dart';

import 'support/screen_harness.dart';

const _library = [
  Song(
    id: 'a',
    title: 'Have It',
    artist: 'Mira',
    album: 'X',
    durationSeconds: 1,
  ),
  Song(
    id: 'c',
    title: 'Also Want',
    artist: 'Third',
    album: 'Z',
    durationSeconds: 1,
  ),
  Song(
    id: 'b',
    title: 'Want It',
    artist: 'Oak',
    album: 'Y',
    durationSeconds: 1,
  ),
];

class _FakeCatalog extends ChangeNotifier implements CatalogController {
  @override
  List<Song> get songs => _library;
  @override
  SearchIndex get searchIndex => SearchIndex(_library);
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

class _FakeCovers extends ChangeNotifier implements PlaylistCoversController {
  @override
  bool hasCover(String id) => false;
  @override
  String? urlFor(String id) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('an imported playlist can add songs from the Add sheet', (
    tester,
  ) async {
    // Arrange
    // Real file work can't finish inside the test's fake clock.
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yomi_imported_add'),
    ))!;
    addTearDown(() => dir.delete(recursive: true));
    final imports = ImportsController(file: File('${dir.path}/imports.json'));
    final playlist = (await tester.runAsync(
      () => imports.add('From Spotify', const [
        ImportEntry(title: 'Have It', artist: 'Mira', songId: 'a'),
      ]),
    ))!;
    await pumpScreen(
      tester,
      ImportedPlaylistPage(playlistId: playlist.id),
      size: const Size(1080, 2340),
      extraProviders: [
        ChangeNotifierProvider<ImportsController>.value(value: imports),
        ChangeNotifierProvider<CatalogController>.value(value: _FakeCatalog()),
        ChangeNotifierProvider<HomeController>.value(value: _FakeHome()),
        ChangeNotifierProvider<AiController>.value(value: _FakeAi()),
        ChangeNotifierProvider<PlaylistCoversController>.value(
          value: _FakeCovers(),
        ),
      ],
    );

    // Act
    await tester.tap(find.widgetWithText(InkWell, 'Add').first);
    await settleScreen(tester);
    expect(find.text('Add to From Spotify'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('add-b')),
        matching: find.byTooltip('Add'),
      ),
    );
    await settleScreen(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('add-c')),
        matching: find.byTooltip('Add'),
      ),
    );
    await settleScreen(tester);

    // Assert
    expect(imports.playlists.single.entries.map((e) => e.songId), [
      'a',
      'b',
      'c',
    ]);
  });
}
