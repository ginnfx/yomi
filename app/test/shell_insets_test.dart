import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/pages/shell_page.dart';
import 'package:yomi/ui/widgets/mini_player.dart';

void main() {
  const systemInsets = EdgeInsets.only(top: 40, bottom: 30);

  Future<EdgeInsets> pagePadding(WidgetTester tester) async {
    EdgeInsets? seen;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: systemInsets),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ShellTabArea(
            header: const SizedBox(height: 10),
            child: Builder(
              builder: (context) {
                seen = MediaQuery.paddingOf(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    return seen!;
  }

  testWidgets('tab pages keep room for the mini player and nav bar', (
    tester,
  ) async {
    // Act
    final padding = await pagePadding(tester);

    // Assert
    expect(padding.bottom, kShellBottomClearance + systemInsets.bottom);
  });

  testWidgets('tab pages do not add the top inset the banners already took', (
    tester,
  ) async {
    // Act
    final padding = await pagePadding(tester);

    // Assert
    expect(padding.top, 0);
  });
}
