import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/compact_music_grid.dart';

void main() {
  testWidgets(
    'desktop shortcuts keep a compact height at different window widths',
    (tester) async {
      for (final width in [500.0, 900.0, 1400.0]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpWidget(
          MaterialApp(
            home: YomiTheme(
              palette: accentPalettes.first,
              isTrueBlack: false,
              child: Scaffold(
                body: CompactMusicGrid(
                  items: [
                    for (var i = 0; i < 6; i++)
                      MusicShortcut(
                        title: 'Song $i',
                        subtitle: 'Artist',
                        coverArtId: null,
                        onTap: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final rect = tester.getRect(
          find
              .ancestor(of: find.text('Song 0'), matching: find.byType(InkWell))
              .first,
        );
        expect(rect.height, 76);
        expect(tester.takeException(), isNull);
      }
      await tester.binding.setSurfaceSize(null);
    },
  );
}
