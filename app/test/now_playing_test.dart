import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/pages/now_playing_page.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/lyrics_view.dart';

import 'support/screen_harness.dart';

void main() {
  setUpAll(loadAppFonts);

  group('Now Playing on a phone', () {
    testWidgets('shows lyrics without any tap when the song has them', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        const NowPlayingPage(),
        size: phoneSize,
        lyrics: demoLyrics,
      );
      expect(find.byType(LyricsView), findsOneWidget);
      expect(find.text('Headlights on the empty road'), findsWidgets);
      expect(find.byTooltip('Lyrics'), findsNothing);
    });

    testWidgets('shows big art and no empty panel without lyrics', (
      tester,
    ) async {
      await pumpScreen(tester, const NowPlayingPage(), size: phoneSize);
      expect(find.byType(LyricsView), findsNothing);
      expect(find.textContaining('No lyrics'), findsNothing);
    });

    testWidgets('tapping the art swaps to big art and remembers it', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        const NowPlayingPage(),
        size: phoneSize,
        lyrics: demoLyrics,
      );
      await tester.tap(find.bySemanticsLabel('Show large artwork'));
      await settleScreen(tester);
      expect(find.byType(LyricsView), findsNothing);

      await pumpScreen(
        tester,
        const NowPlayingPage(),
        size: phoneSize,
        lyrics: demoLyrics,
        prefs: {'prefersArtOverLyrics': true},
      );
      expect(find.byType(LyricsView), findsNothing);
    });

    testWidgets('fits a small phone with no overflow', (tester) async {
      await pumpScreen(
        tester,
        const NowPlayingPage(),
        size: const Size(320, 568),
        lyrics: demoLyrics,
        prefs: {'prefersArtOverLyrics': true},
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('wide screens show art and lyrics side by side', (tester) async {
    await pumpScreen(
      tester,
      const NowPlayingPage(),
      size: wideSize,
      lyrics: demoLyrics,
    );
    final lyrics = tester.getTopLeft(find.byType(LyricsView));
    expect(lyrics.dx, greaterThan(wideSize.width / 2 - 1));
    expect(tester.takeException(), isNull);
  });

  test('measuring accounts for lines that wrap', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final style = yomiText(20);
    final narrow = measureLyricTops(
      lines: const ['a very long line of lyrics that will wrap', 'next'],
      width: 100,
      style: style,
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );
    final wide = measureLyricTops(
      lines: const ['a very long line of lyrics that will wrap', 'next'],
      width: 4000,
      style: style,
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );
    expect(narrow[1], greaterThan(wide[1]));
  });

  group('screenshots', () {
    // Text renders differently per OS, so goldens only compare on the Mac they came from.
    final skip = !Platform.isMacOS;

    testWidgets('phone with lyrics', (tester) async {
      await pumpScreen(
        tester,
        const NowPlayingPage(),
        size: phoneSize,
        lyrics: demoLyrics,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/now_playing_phone_lyrics.png'),
      );
    }, skip: skip);

    testWidgets('phone with art', (tester) async {
      await pumpScreen(tester, const NowPlayingPage(), size: phoneSize);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/now_playing_phone_art.png'),
      );
    }, skip: skip);

    testWidgets('wide with lyrics', (tester) async {
      await pumpScreen(
        tester,
        const NowPlayingPage(),
        size: wideSize,
        lyrics: demoLyrics,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/now_playing_wide_lyrics.png'),
      );
    }, skip: skip);
  });
}
