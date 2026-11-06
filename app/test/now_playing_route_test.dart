import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/pages/now_playing_route.dart';
import 'package:yomi/ui/theme.dart';

void main() {
  const origin = Rect.fromLTWH(8, 700, 384, 56);
  const screen = Size(400, 800);

  group('playerRectAt', () {
    test('starts as the mini bar and ends as the whole screen', () {
      // Act
      final start = playerRectAt(origin, screen, 0);
      final end = playerRectAt(origin, screen, 1);

      // Assert
      expect(start, origin);
      expect(end, Offset.zero & screen);
    });

    test('grows upward from the bar halfway through', () {
      // Act
      final middle = playerRectAt(origin, screen, 0.5);

      // Assert
      expect(middle.top, closeTo(350, 0.01));
      expect(middle.bottom, closeTo(778, 0.01));
      expect(middle.width, greaterThan(origin.width));
    });
  });

  group('NowPlayingRoute', () {
    late NowPlayingRoute route;

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: false,
            child: child!,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                route = NowPlayingRoute(
                  builder: (_) => const ColoredBox(
                    color: Colors.blue,
                    child: Center(child: Text('player')),
                  ),
                  origin: origin,
                  originColor: Colors.red,
                  openDuration: const Duration(milliseconds: 400),
                  closeDuration: const Duration(milliseconds: 300),
                );
                Navigator.of(context).push(route);
              },
              child: const Text('mini bar'),
            ),
          ),
        ),
      );
    }

    double barColourOpacity(WidgetTester tester) => tester
        .widget<Opacity>(
          find.ancestor(
            of: find.byKey(kMiniBarColourKey),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;

    testWidgets('opens covered in the bar colour, which fades into the page', (
      tester,
    ) async {
      // Arrange
      await pumpApp(tester);

      // Act
      await tester.tap(find.text('mini bar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final early = barColourOpacity(tester);
      await tester.pumpAndSettle();

      // Assert
      expect(early, greaterThan(0.9));
      expect(find.byKey(kMiniBarColourKey), findsNothing);
      expect(find.text('player'), findsOneWidget);
    });

    testWidgets('a short drag springs back open', (tester) async {
      // Arrange
      await pumpApp(tester);
      await tester.tap(find.text('mini bar'));
      await tester.pumpAndSettle();

      // Act
      route.dragBy(0.3);
      await tester.pump();
      final during = route.animation!.value;
      route.endDrag(close: false);
      await tester.pumpAndSettle();

      // Assert
      expect(during, closeTo(0.7, 0.001));
      expect(route.animation!.value, 1);
      expect(find.text('player'), findsOneWidget);
    });

    testWidgets('a long drag closes back into the mini bar', (tester) async {
      // Arrange
      await pumpApp(tester);
      await tester.tap(find.text('mini bar'));
      await tester.pumpAndSettle();

      // Act
      route.dragBy(0.6);
      await tester.pump();
      route.endDrag(close: true);
      await tester.pumpAndSettle();

      // Assert
      expect(find.text('player'), findsNothing);
      expect(find.text('mini bar'), findsOneWidget);
    });

    test('dragging follows the finger: the top edge moves by the drag', () {
      // Act
      final fraction = dragFraction(dy: 70, origin: origin, screen: screen);

      // Assert: the top edge travels origin.top over the whole close.
      expect(fraction, closeTo(0.1, 0.0001));
    });
  });
}
