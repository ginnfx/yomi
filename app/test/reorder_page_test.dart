import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/pages/reorder_page.dart';

void main() {
  testWidgets('Done returns the new order, or null when nothing moved', (
    tester,
  ) async {
    List<int>? result = [99];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await reorderSongs(
              context,
              title: 'Mix',
              items: const [
                ReorderItem(title: 'One', subtitle: 'A'),
                ReorderItem(title: 'Two', subtitle: 'B'),
                ReorderItem(title: 'Three', subtitle: 'C'),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final handle = find.byIcon(Icons.drag_handle_rounded).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.toSet(), {0, 1, 2});
    expect(result!.first, isNot(0));
  });
}
