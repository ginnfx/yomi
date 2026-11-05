import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/listening/history_api.dart';
import 'package:yomi/core/listening/listening_stats.dart';
import 'package:yomi/core/listening/past_favourites.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/spotify/spotify_export.dart';
import 'package:yomi/state/ai_controller.dart';
import 'package:yomi/state/listening_log.dart';
import 'package:yomi/ui/stats/stats_page.dart';
import 'package:yomi/ui/stats/wrapped_page.dart';

import 'support/screen_harness.dart';

class _Log extends ChangeNotifier implements ListeningLog {
  _Log(this.events);

  @override
  final List<ListenEvent> events;
  @override
  ImportedHistory get imported => ImportedHistory.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ListenEvent _event(String id, DateTime at, String title) => ListenEvent(
  id: id,
  songId: title,
  artist: 'The Band',
  title: title,
  album: 'Album',
  genre: 'Rock',
  at: at,
  kind: PlayKind.completed,
  seconds: 180,
);

void main() {
  setUpAll(loadAppFonts);

  final now = DateTime(2026, 6, 15, 12);
  Widget page(List<ListenEvent> events) => MultiProvider(
    providers: [
      ChangeNotifierProvider<ListeningLog>.value(value: _Log(events)),
      ChangeNotifierProvider<AiController>(
        create: (_) =>
            AiController(file: File('${Directory.systemTemp.path}/none.json')),
      ),
    ],
    child: StatsPage(now: now),
  );

  testWidgets('shows totals, the chart and top lists', (tester) async {
    await pumpScreen(
      tester,
      page([
        _event('1', DateTime(2026, 6, 1, 21), 'Song One'),
        _event('2', DateTime(2026, 6, 2, 21), 'Song One'),
      ]),
      size: const Size(390, 1400),
    );
    await tester.pump();

    expect(find.text('6'), findsOneWidget); // minutes
    expect(find.text('When you listen'), findsOneWidget);
    expect(find.textContaining('Song One'), findsOneWidget);
    expect(find.text('The Band'), findsOneWidget);
    expect(find.text('Rock'), findsOneWidget);
    expect(find.byType(Tooltip), findsWidgets);
  });

  testWidgets('says so when there is nothing yet', (tester) async {
    await pumpScreen(tester, page(const []), size: phoneSize);
    await tester.pump();

    expect(find.textContaining('Nothing played'), findsOneWidget);
    expect(find.text('When you listen'), findsNothing);
  });

  testWidgets('Wrapped tells the year as a story', (tester) async {
    final stats = computeStats(
      [
        for (var i = 0; i < 3; i++)
          _event('$i', DateTime(2026, 6, i + 1, 23), 'Song One'),
      ],
      range: const StatsRange.year(2026),
      now: now,
    );
    await pumpScreen(
      tester,
      WrappedPage(year: 2026, stats: stats),
      size: phoneSize,
    );
    await tester.pump();

    expect(find.text('9 minutes'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('The Band'), findsOneWidget);
  });

  test('your listening hours name you', () {
    expect(listenerType(7), 'Early riser');
    expect(listenerType(23), 'Night owl');
    expect(listenerType(2), 'Night owl');
  });

  test('thousands get separators and hours read naturally', () {
    expect(formatCount(1234567), '1,234,567');
    expect(formatCount(999), '999');
    expect(formatHour(0), '12 am');
    expect(formatHour(13), '1 pm');
  });

  test('past favourites match by name and need enough plays', () {
    final imported = ImportedHistory.empty().adding([
      for (var i = 0; i < 6; i++)
        HistoryRow(
          at: DateTime.utc(2021, 3, i + 1),
          track: 'Lóve',
          artist: 'Band',
          msPlayed: 60000,
        ),
      HistoryRow(
        at: DateTime.utc(2021, 3, 1),
        track: 'Once',
        artist: 'Band',
        msPlayed: 60000,
      ),
    ]);
    const library = [
      Song(
        id: 'love',
        title: 'Love',
        artist: 'band',
        album: 'A',
        durationSeconds: 1,
      ),
      Song(
        id: 'once',
        title: 'Once',
        artist: 'Band',
        album: 'A',
        durationSeconds: 1,
      ),
    ];
    final found = pastFavourites(imported, library);
    expect(found[2021]!.map((s) => s.id), ['love']);
  });
}
