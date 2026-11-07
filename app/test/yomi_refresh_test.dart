import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/yomi_refresh.dart';

void main() {
  testWidgets('the list slides down instead of sitting under the spinner', (
    tester,
  ) async {
    // Arrange
    final done = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYomiTheme(accentPalettes.first),
        home: YomiTheme(
          palette: accentPalettes.first,
          isTrueBlack: false,
          child: Scaffold(
            body: YomiRefresh(
              onRefresh: () => done.future,
              child: ListView(
                children: const [
                  SizedBox(key: Key('first'), height: 60, child: Text('first')),
                  SizedBox(height: 600),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final restingTop = tester.getTopLeft(find.byKey(const Key('first'))).dy;

    // Act
    await tester.drag(find.text('first'), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    // Assert
    final spinner = tester.getRect(find.byType(RefreshProgressIndicator));
    final firstTop = tester.getTopLeft(find.byKey(const Key('first'))).dy;
    expect(firstTop, greaterThanOrEqualTo(restingTop + kRefreshBand - 1));
    expect(spinner.bottom, lessThanOrEqualTo(firstTop + 1));

    done.complete();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const Key('first'))).dy, restingTop);
  });
}
