import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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

Widget _album() => CollectionPage(
  title: 'Judgment Original Soundtrack',
  subtitle: 'Castlevania Sound Team',
  kind: CollectionKind.album,
  savedSongs: _songs,
  loadSongs: () async => _songs,
);

void main() {
  setUpAll(loadAppFonts);

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

  testWidgets('screenshot', (tester) async {
    await pumpScreen(tester, _album(), size: _phone);

    await expectLater(
      find.byType(CollectionPage),
      matchesGoldenFile('goldens/collection_album.png'),
    );
  });

  testWidgets('screenshot of the song menu', (tester) async {
    await pumpScreen(tester, _album(), size: _phone);
    await tester.tap(find.byTooltip('More options').first);
    await settleScreen(tester);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/song_menu.png'),
    );
  });

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
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/share_sheet.png'),
    );
  });
}
