import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/ai/assistant.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/assistant_controller.dart';

const _library = [
  Song(
    id: 's1',
    title: 'Blue Hour',
    artist: 'Mira',
    album: 'A',
    durationSeconds: 200,
  ),
  Song(
    id: 's2',
    title: 'Red Sky (Remastered)',
    artist: 'Mira feat. Nova',
    album: 'A',
    durationSeconds: 200,
  ),
];

AiApi _api(http.Client client) => AiApi(
  serverUrl: 'http://server',
  auth: SubsonicClient(baseUrl: 'http://server', username: 'u', password: 'p'),
  port: 8443,
  httpClient: client,
);

void main() {
  final index = SearchIndex(_library);

  group('findInLibrary', () {
    test('matches the same song despite case and extra words', () {
      // Act
      final blue = findInLibrary(
        const SuggestedSong(artist: 'mira', title: 'blue hour'),
        index,
      );
      final red = findInLibrary(
        const SuggestedSong(artist: 'Mira', title: 'Red Sky'),
        index,
      );

      // Assert
      expect(blue?.id, 's1');
      expect(red?.id, 's2');
    });

    test('a song by someone else is not a match', () {
      // Act
      final song = findInLibrary(
        const SuggestedSong(artist: 'Somebody', title: 'Blue Hour'),
        index,
      );

      // Assert
      expect(song, isNull);
    });
  });

  group('AssistantController', () {
    late List<Map<String, dynamic>> sent;
    late int status;

    setUp(() {
      sent = [];
      status = 200;
    });

    AssistantController controller() {
      final assistant = AssistantController(
        index: () => index,
        taste: () => (topArtists: ['Mira'], moods: ['calm']),
      );
      assistant.attach(
        _api(
          MockClient((request) async {
            sent.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (status != 200) return http.Response('{}', status);
            return http.Response(
              jsonEncode({
                'reply': 'Here you go.',
                'songs': [
                  {'artist': 'Mira', 'title': 'Blue Hour'},
                  {'artist': 'Nobody', 'title': 'Not Here'},
                ],
                'playlistName': 'Calm',
              }),
              200,
            );
          }),
        ),
      );
      return assistant;
    }

    test('an answer splits into library songs and songs to get', () async {
      // Arrange
      final assistant = controller();

      // Act
      await assistant.ask('something calm');

      // Assert
      final answer = assistant.turns.last.answer!;
      expect(answer.librarySongs.map((s) => s.id), ['s1']);
      expect(answer.missing.map((s) => s.title), ['Not Here']);
      expect(answer.playlistName, 'Calm');
      expect(sent.single['taste'], {
        'topArtists': ['Mira'],
        'moods': ['calm'],
      });
    });

    test(
      'the conversation so far goes with each question, within the limit',
      () async {
        // Arrange
        final assistant = controller();

        // Act
        for (var i = 0; i < 8; i++) {
          await assistant.ask('question $i');
        }

        // Assert
        final messages = sent.last['messages'] as List<dynamic>;
        expect(messages, hasLength(kAssistantHistory));
        expect((messages.last as Map)['text'], 'question 7');
        expect((messages.last as Map)['role'], 'user');
      },
    );

    test('a refusal keeps the question and explains', () async {
      // Arrange
      status = 429;
      final assistant = controller();

      // Act
      await assistant.ask('hello');

      // Assert
      expect(assistant.turns.single.text, 'hello');
      expect(assistant.error, contains('a lot of questions'));
      expect(assistant.isThinking, isFalse);
    });

    test('blank questions are ignored', () async {
      // Arrange
      final assistant = controller();

      // Act
      await assistant.ask('   ');

      // Assert
      expect(assistant.turns, isEmpty);
      expect(sent, isEmpty);
    });
  });

  group('DiscoverController', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test(
      'keeps only songs the library lacks and asks at most weekly',
      () async {
        // Arrange
        var calls = 0;
        var now = DateTime(2026, 11, 6);
        final discover = DiscoverController(
          await SharedPreferences.getInstance(),
          index: () => index,
          taste: () => (topArtists: ['Mira'], moods: ['calm']),
          now: () => now,
        );
        discover.attach(
          _api(
            MockClient((_) async {
              calls++;
              return http.Response(
                jsonEncode({
                  'songs': [
                    {'artist': 'Mira', 'title': 'Blue Hour', 'reason': 'yours'},
                    {'artist': 'Nova', 'title': 'Fresh', 'reason': 'new'},
                  ],
                }),
                200,
              );
            }),
          ),
        );

        // Act
        await discover.refreshIfDue();
        now = now.add(const Duration(days: 3));
        await discover.refreshIfDue();

        // Assert
        expect(discover.songs.map((s) => s.title), ['Fresh']);
        expect(calls, 1);
      },
    );
  });
}
