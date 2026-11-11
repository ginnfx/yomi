import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/ai_controller.dart';
import 'package:yomi/state/assistant_controller.dart';
import 'package:yomi/state/settings.dart';
import 'package:yomi/ui/settings/assistant_section.dart';
import 'package:yomi/ui/theme.dart';

void main() {
  testWidgets('recovered server enables Ask Yomi and the switch stays on', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var reachable = false;
    late Directory dir;
    late AiController ai;
    late SettingsController settings;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('assistant-activation');
      settings = await SettingsController.load();
      ai = AiController(file: File('${dir.path}/labels.json'));
      ai.attach(
        AiApi(
          serverUrl: 'http://cloud:4533',
          auth: SubsonicClient(
            baseUrl: 'http://cloud:4533',
            username: 'u',
            password: 'p',
          ),
          port: 4534,
          httpClient: MockClient((_) async {
            if (!reachable) throw http.ClientException('tunnel not ready');
            return http.Response(
              '{"available":true,"songs":{},"artists":{}}',
              200,
            );
          }),
        ),
      );
      await ai.refresh();
    });
    final assistant = AssistantController(
      index: () => SearchIndex(const []),
      taste: () => (topArtists: const [], moods: const []),
    );
    addTearDown(() async {
      ai.dispose();
      assistant.dispose();
      settings.dispose();
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AiController>.value(value: ai),
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<AssistantController>.value(value: assistant),
        ],
        child: MaterialApp(
          builder: (context, child) => YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: true,
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(child: AssistantSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, 'Ask Yomi');
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);

    reachable = true;
    await tester.runAsync(() async {
      await tester.tap(find.text('Check again'));
      await ai.refresh();
    });
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    await tester.tap(find.text('Ask Yomi'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(settings.isAssistantOn, isTrue);
    expect((await SettingsController.load()).isAssistantOn, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
