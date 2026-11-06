import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/mini_player.dart';

import 'support/screen_harness.dart';

class _Opener extends StatelessWidget {
  const _Opener();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => Navigator.of(context).push(
        yomiRoute<void>(builder: (_) => const Scaffold(body: Text('page'))),
      ),
      child: const Text('open'),
    ),
  );
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('a pushed page shows the mini player while a song plays', (
    tester,
  ) async {
    // Arrange
    await pumpScreen(tester, const _Opener(), size: phoneSize);

    // Act
    await tester.tap(find.text('open'));
    await settleScreen(tester);

    // Assert
    expect(find.text('page'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
  });

  testWidgets('a pushed page shows no mini player when nothing plays', (
    tester,
  ) async {
    // Arrange
    await pumpScreen(tester, const _Opener(), size: phoneSize, song: null);

    // Act
    await tester.tap(find.text('open'));
    await settleScreen(tester);

    // Assert
    expect(find.text('page'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsNothing);
  });
}
