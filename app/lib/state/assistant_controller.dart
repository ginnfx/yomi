import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ai/ai_api.dart';
import '../core/ai/assistant.dart';
import '../core/search_index.dart';

/// How many turns go with each question; the server takes at most 12.
const int kAssistantHistory = 12;

/// How often "You might like" asks for new songs.
const Duration kDiscoverEvery = Duration(days: 7);

const String _discoverKey = 'discover.songs';
const String _discoverAtKey = 'discover.at';

/// The little the AI is told about someone's listening.
typedef TasteSummary = ({List<String> topArtists, List<String> moods});

String _describe(Object error) {
  if (error is http.ClientException && !error.message.contains('answered')) {
    return error.message;
  }
  if (error is TimeoutException)
    return 'The assistant took too long. Try again.';
  return "The assistant couldn't answer right now.";
}

/// "Ask Yomi": a conversation with the DeepSeek music assistant, kept on this device.
class AssistantController extends ChangeNotifier {
  AssistantController({required this.index, required this.taste});

  final SearchIndex Function() index;
  final TasteSummary Function() taste;
  AiApi? _api;
  List<ChatTurn> _turns = const [];
  bool _isThinking = false;
  String? _error;

  List<ChatTurn> get turns => _turns;
  bool get isThinking => _isThinking;
  bool get isAvailable => _api != null;
  String? get error => _error;

  void attach(AiApi? api) {
    _api = api;
    notifyListeners();
  }

  void clear() {
    _turns = const [];
    _error = null;
    notifyListeners();
  }

  Future<void> ask(String question) async {
    final text = question.trim();
    final api = _api;
    if (text.isEmpty || api == null || _isThinking) return;
    _turns = List.unmodifiable([..._turns, ChatTurn.user(text)]);
    _isThinking = true;
    _error = null;
    notifyListeners();
    try {
      final summary = taste();
      final history = _turns.length > kAssistantHistory
          ? _turns.sublist(_turns.length - kAssistantHistory)
          : _turns;
      final answer = await api.chat(
        history,
        topArtists: summary.topArtists,
        moods: summary.moods,
      );
      _turns = List.unmodifiable([
        ..._turns,
        ChatTurn.assistant(answer.matchedWith(index())),
      ]);
    } on Exception catch (error) {
      debugPrint('Assistant failed: $error');
      _error = _describe(error);
    } finally {
      _isThinking = false;
      notifyListeners();
    }
  }
}

/// "You might like": songs the library doesn't have, suggested once a week.
class DiscoverController extends ChangeNotifier {
  DiscoverController(
    this._prefs, {
    required this.index,
    required this.taste,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SharedPreferences _prefs;
  final SearchIndex Function() index;
  final TasteSummary Function() taste;
  final DateTime Function() _now;
  AiApi? _api;
  bool _isLoading = false;

  void attach(AiApi? api) {
    _api = api;
    notifyListeners();
  }

  /// Saved suggestions, without any the library has gained since.
  List<SuggestedSong> get songs {
    final saved = _prefs.getString(_discoverKey);
    if (saved == null) return const [];
    try {
      final library = index();
      return List.unmodifiable([
        for (final item in (jsonDecode(
          saved,
        ) as List<dynamic>).whereType<Map<String, dynamic>>())
          if (SuggestedSong.fromJson(item) case final song
              when findInLibrary(song, library) == null)
            song,
      ]);
    } on FormatException {
      return const [];
    }
  }

  Future<void> refreshIfDue() async {
    final api = _api;
    if (api == null || _isLoading) return;
    final at = _prefs.getInt(_discoverAtKey);
    if (at != null &&
        _now().difference(DateTime.fromMillisecondsSinceEpoch(at)) <
            kDiscoverEvery) {
      return;
    }
    final summary = taste();
    if (summary.topArtists.isEmpty && summary.moods.isEmpty) return;
    _isLoading = true;
    try {
      final found = await api.discover(
        topArtists: summary.topArtists,
        moods: summary.moods,
      );
      await _prefs.setString(
        _discoverKey,
        jsonEncode([
          for (final song in found)
            {'artist': song.artist, 'title': song.title, 'reason': song.reason},
        ]),
      );
      await _prefs.setInt(_discoverAtKey, _now().millisecondsSinceEpoch);
    } on Exception catch (error) {
      // Tried again the next time Home opens.
      debugPrint('Discover failed: $error');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
