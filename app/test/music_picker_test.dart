import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/messaging/music_to_send.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/player_controller.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/song_picker_sheet.dart';

import 'support/screen_harness.dart';

const _songs = [
  Song(
    id: 's1',
    title: 'Blue Hour',
    artist: 'Mira',
    album: 'Night Drive',
    albumId: 'a1',
    durationSeconds: 200,
    isStarred: true,
  ),
  Song(
    id: 's2',
    title: 'Red Sky',
    artist: 'Mira',
    album: 'Night Drive',
    albumId: 'a1',
    durationSeconds: 210,
  ),
];

class _FakeCatalog extends ChangeNotifier implements CatalogController {
  @override
  List<Song> get songs => _songs;
  @override
  SearchIndex get searchIndex => SearchIndex(_songs);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yomi_picker');
  });
  tearDown(() => dir.delete(recursive: true));

  /// Opens the picker and returns what it hands back once closed.
  Future<Future<PickedMusic?> Function()> openPicker(
    WidgetTester tester, {
    List<Playlist> playlists = const [],
  }) async {
    PickedMusic? picked;
    var isClosed = false;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<CatalogController>.value(
            value: _FakeCatalog(),
          ),
          ChangeNotifierProvider<PlayHistory>.value(
            value: PlayHistory(File('${dir.path}/history.jsonl')),
          ),
          ChangeNotifierProvider<PlayerController>.value(
            value: FakePlayer(null),
          ),
        ],
        child: MaterialApp(
          theme: buildYomiTheme(accentPalettes.first),
          builder: (context, inner) => YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: false,
            child: inner!,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await pickMusicToSend(
                  context,
                  loadPlaylists: () async => playlists,
                );
                isClosed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    return () async {
      expect(isClosed, isTrue, reason: 'the picker should have closed');
      return picked;
    };
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('offers tabs to browse without typing', (tester) async {
    // Arrange
    await openPicker(tester);

    // Act
    await show(tester);

    // Assert
    for (final tab in ['Recent', 'Songs', 'Albums', 'Playlists', 'Liked']) {
      expect(find.widgetWithText(ChoiceChip, tab), findsOneWidget);
    }
  });

  testWidgets('sends a whole album from the Albums tab', (tester) async {
    // Arrange
    final result = await openPicker(tester);
    await show(tester);

    // Act
    await tester.tap(find.widgetWithText(ChoiceChip, 'Albums'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Night Drive'));
    await tester.pumpAndSettle();

    // Assert
    final picked = await result();
    expect(picked, isA<PickedAlbum>());
    expect(picked!.message.albumId, 'a1');
  });

  testWidgets('the Liked tab shows only liked songs', (tester) async {
    // Arrange
    await openPicker(tester);
    await show(tester);

    // Act
    await tester.tap(find.widgetWithText(ChoiceChip, 'Liked'));
    await tester.pumpAndSettle();

    // Assert
    expect(find.text('Blue Hour'), findsOneWidget);
    expect(find.text('Red Sky'), findsNothing);
  });

  testWidgets('search finds a playlist and sends it', (tester) async {
    // Arrange
    final result = await openPicker(
      tester,
      playlists: const [
        Playlist(
          id: 'p1',
          name: 'Night walks',
          songCount: 4,
          durationSeconds: 1,
        ),
      ],
    );
    await show(tester);

    // Act
    await tester.enterText(find.byType(TextField), 'night');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Night walks'));
    await tester.pumpAndSettle();

    // Assert
    final picked = await result();
    expect(picked!.message.playlistId, 'p1');
  });
}
