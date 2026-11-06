import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/taste.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/add_songs_sheet.dart';

import 'support/screen_harness.dart';

Song _song(String id, String title, String artist) => Song(
  id: id,
  title: title,
  artist: artist,
  album: 'Album $id',
  durationSeconds: 180,
);

final _library = [
  _song('1', 'Blue Hour', 'Mira'),
  _song('2', 'Red Sky', 'Mira'),
  _song('3', 'Green Room', 'Oak'),
  _song('4', 'Already Here', 'Oak'),
];

void main() {
  Future<List<String>> pumpSheet(
    WidgetTester tester, {
    Future<void> Function(Song song)? onAdd,
    TasteProfile taste = const TasteProfile(),
    List<Song>? library,
    int limit = 100,
  }) async {
    final added = <String>[];
    final songs = library ?? _library;
    final changes = StreamController<List<ConnectivityResult>>();
    addTearDown(changes.close);
    final connectivity = ConnectivityController(
      changes: changes.stream,
      check: () => Future.error(StateError('no system bus')),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SessionController>.value(value: FakeSession()),
          ChangeNotifierProvider<ConnectivityController>.value(
            value: connectivity,
          ),
        ],
        child: MaterialApp(
          theme: buildYomiTheme(accentPalettes.first),
          home: YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: false,
            child: Scaffold(
              body: AddSongsSheet(
                playlistName: 'Road trip',
                library: songs,
                searchIndex: SearchIndex(songs),
                taste: taste,
                alreadyIn: {'4'},
                random: Random(1),
                suggestionCount: limit,
                onAdd:
                    onAdd ??
                    (song) async {
                      added.add(song.id);
                    },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return added;
  }

  testWidgets('suggests songs the playlist does not have yet', (tester) async {
    await pumpSheet(tester);

    expect(find.text('Blue Hour'), findsOneWidget);
    expect(find.text('Green Room'), findsOneWidget);
    expect(find.text('Already Here'), findsNothing);
  });

  testWidgets('puts songs matching your taste first', (tester) async {
    await pumpSheet(tester, taste: const TasteProfile(songs: {'3': 10}));

    final first = tester.getTopLeft(find.text('Green Room')).dy;
    final second = tester.getTopLeft(find.text('Blue Hour')).dy;
    expect(first, lessThan(second));
  });

  testWidgets('lists no more than the suggestion limit', (tester) async {
    await pumpSheet(tester, limit: 2);

    expect(find.byTooltip('Add'), findsNWidgets(2));
  });

  testWidgets('typing searches the whole library', (tester) async {
    await pumpSheet(tester);

    await tester.enterText(find.byType(TextField), 'green');
    await tester.pump();

    expect(find.text('Green Room'), findsOneWidget);
    expect(find.text('Blue Hour'), findsNothing);
  });

  testWidgets('says so when nothing matches', (tester) async {
    await pumpSheet(tester);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pump();

    expect(find.text('Nothing matches that.'), findsOneWidget);
  });

  testWidgets('one tap adds a song and marks it added', (tester) async {
    final added = await pumpSheet(tester);

    await tester.tap(find.byTooltip('Add').first);
    await tester.pump();

    expect(added, hasLength(1));
    expect(find.byTooltip('Added'), findsOneWidget);
  });

  testWidgets('an added song cannot be added twice', (tester) async {
    final added = await pumpSheet(tester);
    await tester.tap(find.byTooltip('Add').first);
    await tester.pump();

    await tester.tap(find.byTooltip('Added'), warnIfMissed: false);
    await tester.pump();

    expect(added, hasLength(1));
  });

  testWidgets('a failed add can be tried again', (tester) async {
    var shouldFail = true;
    await pumpSheet(
      tester,
      onAdd: (song) async {
        if (shouldFail) throw Exception('offline');
      },
    );

    await tester.tap(find.byTooltip('Add').first);
    await tester.pump();
    shouldFail = false;
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byTooltip('Added'), findsNothing);
    expect(find.byTooltip('Add'), findsWidgets);
  });

  testWidgets('shows the playlist it adds to and a way to close', (
    tester,
  ) async {
    await pumpSheet(tester);

    expect(find.text('Add to Road trip'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });
}
