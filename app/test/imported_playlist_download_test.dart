import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/cover_palette.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/ui/pages/collection_header.dart';
import 'package:yomi/ui/widgets/playlist_cover.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/core/taste.dart';
import 'package:yomi/state/ai_controller.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/download_manager.dart';
import 'package:yomi/state/home_controller.dart';
import 'package:yomi/state/imports_controller.dart';
import 'package:yomi/state/playlist_covers_controller.dart';
import 'package:yomi/ui/imports/imported_playlist_page.dart';

import 'support/screen_harness.dart';

const _library = [
  Song(id: 'a', title: 'One', artist: 'X', album: 'A', durationSeconds: 1),
  Song(id: 'b', title: 'Two', artist: 'Y', album: 'B', durationSeconds: 1),
];

class _Catalog extends ChangeNotifier implements CatalogController {
  @override
  List<Song> get songs => _library;
  @override
  SearchIndex get searchIndex => SearchIndex(_library);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Home extends ChangeNotifier implements HomeController {
  @override
  TasteProfile get taste => TasteProfile.empty;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ai extends ChangeNotifier implements AiController {
  @override
  Map<String, List<String>> get similarArtists => const {};
  @override
  SongTag? tagFor(Song song) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Covers extends ChangeNotifier implements PlaylistCoversController {
  String? picture;
  void setPicture(String url) {
    picture = url;
    notifyListeners();
  }

  @override
  bool hasCover(String id) => picture != null;
  @override
  String? urlFor(String id) => picture;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Palette extends CoverPalette {
  final requested = <String>[];
  @override
  Future<Color?> colorForImage(
    String key,
    ImageProvider Function() provider,
  ) async {
    requested.add(key);
    return key.contains('teal') ? Colors.teal : Colors.pink;
  }

  @override
  Future<Color?> colorFor(SubsonicClient client, String? coverArtId) async =>
      null;
}

/// Pretends the songs in [saved] are on the device.
class _Downloads extends FakeDownloads {
  _Downloads({Set<String> saved = const {}}) : _saved = {...saved};

  final Set<String> _saved;
  final List<String> enqueued = [];
  final List<String> removed = [];

  @override
  DownloadStatus statusOf(String songId) =>
      _saved.contains(songId) ? DownloadStatus.done : DownloadStatus.none;
  @override
  int downloadedCountOf(Iterable<Song> songs) =>
      songs.where((s) => _saved.contains(s.id)).length;
  @override
  void enqueue(Iterable<Song> songs, {bool isAuto = false}) =>
      enqueued.addAll(songs.map((s) => s.id));
  @override
  Future<void> remove(Song song) async => removed.add(song.id);
}

void main() {
  setUpAll(loadAppFonts);

  Future<_Downloads> pumpImport(
    WidgetTester tester, {
    Set<String> saved = const {},
    List<ImportEntry>? entries,
    _Covers? covers,
    CoverPalette? palette,
  }) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yomi_import_dl'),
    ))!;
    addTearDown(() => dir.delete(recursive: true));
    final imports = ImportsController(file: File('${dir.path}/imports.json'));
    final playlist = (await tester.runAsync(
      () => imports.add(
        'Spotify mix',
        entries ??
            const [
              ImportEntry(title: 'One', artist: 'X', songId: 'a'),
              ImportEntry(title: 'Two', artist: 'Y', songId: 'b'),
              ImportEntry(title: 'Missing', artist: 'Z'),
            ],
      ),
    ))!;
    final downloads = _Downloads(saved: saved);
    await pumpScreen(
      tester,
      ImportedPlaylistPage(playlistId: playlist.id),
      size: const Size(1080, 2340),
      extraProviders: [
        if (palette != null) Provider<CoverPalette>.value(value: palette),
        ChangeNotifierProvider<ImportsController>.value(value: imports),
        ChangeNotifierProvider<CatalogController>.value(value: _Catalog()),
        ChangeNotifierProvider<PlaylistCoversController>.value(
          value: covers ?? _Covers(),
        ),
        ChangeNotifierProvider<DownloadManager>.value(value: downloads),
        ChangeNotifierProvider<HomeController>.value(value: _Home()),
        ChangeNotifierProvider<AiController>.value(value: _Ai()),
      ],
    );
    return downloads;
  }

  testWidgets(
    'imported playlist background follows the custom picture, not the accent',
    (tester) async {
      final covers = _Covers()..picture = 'https://images.example/teal.jpg';
      final palette = _Palette();
      await pumpImport(tester, covers: covers, palette: palette);
      await settleScreen(tester);
      final context = tester.element(find.byType(CollectionHeader));
      final page = context.pageColor;
      expect(
        tester.widget<CollectionHeader>(find.byType(CollectionHeader)).color,
        Color.lerp(page, Colors.teal, headerTintStrength),
      );
      covers.setPicture('https://images.example/pink.jpg');
      await settleScreen(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.widget<CollectionHeader>(find.byType(CollectionHeader)).color,
        Color.lerp(page, Colors.pink, headerTintStrength),
      );
      expect(
        palette.requested,
        containsAll([
          'https://images.example/teal.jpg',
          'https://images.example/pink.jpg',
        ]),
      );
      final cover = find.byType(PlaylistCover).first;
      for (final element
          in find
              .descendant(of: cover, matching: find.byType(DecoratedBox))
              .evaluate()) {
        final decoration = (element.widget as DecoratedBox).decoration;
        if (decoration is BoxDecoration) expect(decoration.boxShadow, isNull);
      }
    },
  );

  testWidgets('downloads the songs of an import that are in the library', (
    tester,
  ) async {
    final downloads = await pumpImport(tester);

    await tester.tap(find.byTooltip('Download'));
    await tester.pump();

    expect(downloads.enqueued, ['a', 'b']);
  });

  testWidgets('a fully saved import offers to remove its downloads', (
    tester,
  ) async {
    final downloads = await pumpImport(tester, saved: {'a', 'b'});

    await tester.tap(find.byTooltip('Remove download'));
    await tester.pump();

    expect(downloads.removed, ['a', 'b']);
  });

  testWidgets('an import with nothing in the library cannot be downloaded', (
    tester,
  ) async {
    final downloads = await pumpImport(
      tester,
      entries: const [ImportEntry(title: 'Missing', artist: 'Z')],
    );

    await tester.tap(find.byTooltip('Download'), warnIfMissed: false);
    await tester.pump();

    expect(downloads.enqueued, isEmpty);
  });
}
