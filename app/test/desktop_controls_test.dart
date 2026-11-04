import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/state/player_controller.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/ui/widgets/desktop_controls.dart';

class _Player extends ChangeNotifier implements PlayerController {
  int toggles = 0;
  @override
  Song? get current => const Song(
    id: '1',
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    durationSeconds: 10,
  );
  @override
  bool get isPlaying => false;
  @override
  Future<void> togglePlay() async {
    toggles++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends ChangeNotifier implements SessionController {
  @override
  bool get isSignedIn => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Space toggles playback while leaving text editing alone', (
    tester,
  ) async {
    final player = _Player();
    final session = _Session();
    final navigator = GlobalKey<NavigatorState>();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<SessionController>.value(value: session),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          builder: (_, child) =>
              DesktopControls(navigatorKey: navigator, child: child!),
          home: Scaffold(
            body: Column(
              children: [
                Focus(focusNode: focus, child: const Text('Playback')),
                const TextField(),
              ],
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.toggles, 1);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.toggles, 1);
    await tester.enterText(find.byType(TextField), 'Miles Davis');
    expect(find.text('Miles Davis'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
    session.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
}
