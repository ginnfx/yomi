import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/async_section.dart';
import 'package:yomi/ui/widgets/fade_on_change.dart';

import 'support/screen_harness.dart';

void main() {
  Future<void> pumpRoutes(WidgetTester tester, {required bool reduce}) =>
      tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: false,
            reduceMotion: reduce,
            child: child!,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                yomiRoute<void>(builder: (_) => const Text('second page')),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );

  testWidgets('pages slide in normally', (tester) async {
    // Arrange
    await pumpRoutes(tester, reduce: false);

    // Act
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // Assert: mid-transition, both pages are on screen.
    expect(find.text('go'), findsOneWidget);
    expect(find.text('second page'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('with reduce motion a page appears at once', (tester) async {
    // Arrange
    await pumpRoutes(tester, reduce: true);

    // Act
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();

    // Assert
    expect(find.text('go'), findsNothing);
    expect(find.text('second page'), findsOneWidget);
  });

  testWidgets('a section fades from its skeleton to its content', (
    tester,
  ) async {
    // Arrange
    final loaded = Completer<String>();
    await pumpScreen(
      tester,
      ChangeNotifierProvider(
        create: (_) => ConnectivityController(
          changes: const Stream<List<ConnectivityResult>>.empty(),
          check: () async => [ConnectivityResult.wifi],
        ),
        child: ChangeNotifierProvider<SessionController>.value(
          value: FakeSession(),
          child: Material(
            child: AsyncSection<String>(
              load: () => loaded.future,
              skeleton: const Text('skeleton'),
              builder: (_, value) => Text(value),
            ),
          ),
        ),
      ),
      size: phoneSize,
    );

    // Act
    loaded.complete('content');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Assert: both are on screen while one fades into the other.
    expect(find.text('skeleton'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('skeleton'), findsNothing);
  });

  testWidgets('a tab fade keeps the page it fades', (tester) async {
    // Arrange
    final field = TextEditingController();
    Widget page(int tab) => MaterialApp(
      home: Material(
        child: FadeOnChange(
          trigger: tab,
          child: TextField(controller: field),
        ),
      ),
    );
    await tester.pumpWidget(page(0));
    await tester.enterText(find.byType(TextField), 'kept');
    final before = tester.state(find.byType(EditableText));

    // Act
    await tester.pumpWidget(page(1));
    await tester.pump(const Duration(milliseconds: 50));

    // Assert
    expect(tester.state(find.byType(EditableText)), same(before));
    final fade = tester.widget<FadeTransition>(
      find.descendant(
        of: find.byType(FadeOnChange),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
  });
}
