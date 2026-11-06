import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/assistant_controller.dart';
import 'package:yomi/ui/assistant/assistant_page.dart';

import 'support/screen_harness.dart';

const _library = [
  Song(
    id: 's1',
    title: 'Blue Hour',
    artist: 'Mira',
    album: 'A',
    durationSeconds: 200,
  ),
];

void main() {
  testWidgets('an answer offers to play library songs and fetch the rest', (
    tester,
  ) async {
    // Arrange
    final assistant =
        AssistantController(
          index: () => SearchIndex(_library),
          taste: () => (topArtists: const <String>[], moods: const <String>[]),
        )..attach(
          AiApi(
            serverUrl: 'http://server',
            auth: SubsonicClient(
              baseUrl: 'http://server',
              username: 'u',
              password: 'p',
            ),
            port: 8443,
            httpClient: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'reply': 'Try these.',
                  'songs': [
                    {'artist': 'Mira', 'title': 'Blue Hour'},
                    {'artist': 'Nova', 'title': 'Elsewhere'},
                  ],
                }),
                200,
              ),
            ),
          ),
        );
    await pumpScreen(
      tester,
      ChangeNotifierProvider.value(
        value: assistant,
        child: const AssistantPage(),
      ),
      size: phoneSize,
    );

    // Act
    await tester.tap(find.text('Something calm for studying'));
    await settleScreen(tester);

    // Assert
    expect(find.text('Try these.'), findsOneWidget);
    expect(find.text('Play 1'), findsOneWidget);
    expect(find.text('Nova · Not in your library'), findsOneWidget);
    expect(find.byTooltip('Find on YouTube'), findsOneWidget);
    expect(find.byTooltip('Request it'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
