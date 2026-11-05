import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/pages/settings_page.dart';

import 'support/screen_harness.dart';

void main() {
  testWidgets('the first screen is a short list', (tester) async {
    await pumpScreen(tester, const SettingsPage(), size: phoneSize);

    for (final title in ['Profile', 'Appearance', 'Storage', 'Advanced', 'Sign out']) {
      expect(find.text(title), findsWidgets);
    }
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('Cache songs as you listen'), findsNothing);
    expect(find.text('Preload next songs'), findsNothing);
    expect(find.text('Save songs on repeat'), findsNothing);
  });
}
