import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/app_info.dart';
import 'package:yomi/state/update_controller.dart';
import 'package:yomi/ui/pages/settings_page.dart';

import 'support/screen_harness.dart';

void main() {
  testWidgets('the first screen is a short list', (tester) async {
    await pumpScreen(tester, const SettingsPage(), size: phoneSize);

    for (final title in [
      'Profile',
      'Appearance',
      'Storage',
      'Advanced',
      'Sign out',
    ]) {
      expect(find.text(title), findsWidgets);
    }
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('Cache songs as you listen'), findsNothing);
    expect(find.text('Preload next songs'), findsNothing);
    expect(find.text('Save songs on repeat'), findsNothing);
  });

  testWidgets('shows the app version at the bottom', (tester) async {
    addTearDown(() => appInfo = const AppInfo());
    appInfo = const AppInfo(version: '9.8.7', platform: 'android');
    await pumpScreen(tester, const SettingsPage(), size: phoneSize);

    await scrollTo(tester, find.text('Yomi 9.8.7'));
    expect(find.text('Yomi 9.8.7'), findsOneWidget);
  });

  testWidgets('shows the build number next to the version', (tester) async {
    // Arrange
    addTearDown(() => appInfo = const AppInfo());
    appInfo = const AppInfo(
      version: '9.8.7',
      buildNumber: '90807',
      platform: 'android',
    );

    // Act
    await pumpScreen(tester, const SettingsPage(), size: phoneSize);
    await scrollTo(tester, find.text('Yomi 9.8.7 (90807)'));

    // Assert
    expect(find.text('Yomi 9.8.7 (90807)'), findsOneWidget);
    expect(
      find.widgetWithText(SelectableText, 'Yomi 9.8.7 (90807)'),
      findsOneWidget,
    );
  });

  group('check for updates', () {
    Future<void> tapCheck(WidgetTester tester, _FakeUpdates updates) async {
      addTearDown(() => appInfo = const AppInfo());
      appInfo = const AppInfo(version: '9.8.7', platform: 'android');
      await pumpScreen(
        tester,
        ChangeNotifierProvider<UpdateController>.value(
          value: updates,
          child: const SettingsPage(),
        ),
        size: phoneSize,
      );
      await scrollTo(tester, find.text('Check for updates'));
      await tester.tap(find.text('Check for updates'));
      await settleScreen(tester);
    }

    testWidgets('says so when this is the latest version', (tester) async {
      // Arrange
      final updates = _FakeUpdates(UpdateCheckResult.upToDate);

      // Act
      await tapCheck(tester, updates);

      // Assert
      expect(updates.checks, 1);
      expect(find.text('You have the latest version'), findsOneWidget);
    });

    testWidgets('names the new version when there is one', (tester) async {
      // Arrange
      final updates = _FakeUpdates(UpdateCheckResult.available);

      // Act
      await tapCheck(tester, updates);

      // Assert
      expect(find.textContaining('A new version is ready'), findsOneWidget);
    });

    testWidgets('explains a failed check', (tester) async {
      // Arrange
      final updates = _FakeUpdates(UpdateCheckResult.failed);

      // Act
      await tapCheck(tester, updates);

      // Assert
      expect(find.textContaining("Couldn't check for updates"), findsOneWidget);
    });

    testWidgets('is hidden where the app cannot update itself', (tester) async {
      // Arrange
      addTearDown(() => appInfo = const AppInfo());
      appInfo = const AppInfo(version: '9.8.7', platform: 'ios');

      // Act
      await pumpScreen(
        tester,
        ChangeNotifierProvider<UpdateController>.value(
          value: _FakeUpdates(
            UpdateCheckResult.unsupported,
            mode: UpdateMode.disabled,
          ),
          child: const SettingsPage(),
        ),
        size: phoneSize,
      );
      await scrollTo(tester, find.text('Yomi 9.8.7'));

      // Assert
      expect(find.text('Check for updates'), findsNothing);
    });
  });
}

class _FakeUpdates extends ChangeNotifier implements UpdateController {
  _FakeUpdates(this.result, {this.mode = UpdateMode.androidInstall});

  final UpdateCheckResult result;
  @override
  final UpdateMode mode;
  int checks = 0;

  @override
  Future<UpdateCheckResult> checkNow() async {
    checks++;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The page's own list; SelectableText brings a scrollable of its own.
Future<void> scrollTo(WidgetTester tester, Finder target) => tester
    .scrollUntilVisible(target, 200, scrollable: find.byType(Scrollable).first);
