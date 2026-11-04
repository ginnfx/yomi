import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/ui/pages/login_page.dart';
import 'package:yomi/ui/theme.dart';

void main() {
  testWidgets(
    'normal sign-in needs only account credentials, with editable advanced addresses',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildYomiTheme(accentPalettes.first),
          home: YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: false,
            child: const LoginPage(),
          ),
        ),
      );
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('Username'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Server address'), findsNothing);
      await tester.tap(find.text('Advanced connection settings'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(4));
      expect(find.text('http://100.88.180.104:4533'), findsOneWidget);
      expect(find.text('http://192.168.1.18:4533'), findsOneWidget);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.iOS}),
  );
}
