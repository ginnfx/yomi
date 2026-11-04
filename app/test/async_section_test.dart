import 'package:yomi/state/session.dart';
import 'package:provider/provider.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/widgets/async_section.dart';
import 'package:yomi/ui/widgets/error_view.dart';

import 'support/screen_harness.dart';

class _Session extends FakeSession {
  @override
  ActiveRoute get route => ActiveRoute.home;
  @override
  bool get hasHomeAddress => true;
}

void main() {
  testWidgets('a stalled section times out and retry can recover', (
    tester,
  ) async {
    var attempts = 0;
    await pumpScreen(
      tester,
      ChangeNotifierProvider(
        create: (_) => ConnectivityController(
          changes: const Stream<List<ConnectivityResult>>.empty(),
          check: () async => [ConnectivityResult.wifi],
        ),
        child: ChangeNotifierProvider<SessionController>.value(
          value: _Session(),
          child: Material(
            child: AsyncSection<String>(
              load: () {
                attempts++;
                return attempts == 1
                    ? Completer<String>().future
                    : Future.value('Loaded');
              },
              builder: (_, value) => Text(value),
            ),
          ),
        ),
      ),
      size: phoneSize,
    );
    await tester.pump(const Duration(seconds: 21));
    await tester.pump();
    expect(find.byType(ErrorView), findsOneWidget);
    tester.widget<ErrorView>(find.byType(ErrorView)).onRetry!();
    await tester.pumpAndSettle();
    expect(find.text('Loaded'), findsOneWidget);
  });
}
