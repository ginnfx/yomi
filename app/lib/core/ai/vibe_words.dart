import 'ai_api.dart';

/// Moods offered as one-tap chips, from the 12 the AI labels songs with.
const List<String> kVibeChips = [
  'happy',
  'calm',
  'energetic',
  'sad',
  'focus',
  'party',
  'romantic',
  'dreamy',
  'nostalgic',
  'uplifting',
  'dark',
  'angry',
];

/// Everyday words, and the moods and energy they mean.
const Map<String, ({List<String> moods, String? energy})> _vibes = {
  'happy': (moods: ['happy'], energy: null),
  'sad': (moods: ['sad'], energy: null),
  'calm': (moods: ['calm'], energy: null),
  'chill': (moods: ['calm'], energy: null),
  'relaxing': (moods: ['calm'], energy: null),
  'relax': (moods: ['calm'], energy: null),
  'energetic': (moods: ['energetic'], energy: null),
  'upbeat': (moods: ['energetic', 'happy'], energy: null),
  'hype': (moods: ['party', 'energetic'], energy: 'high'),
  'romantic': (moods: ['romantic'], energy: null),
  'love': (moods: ['romantic'], energy: null),
  'angry': (moods: ['angry'], energy: null),
  'aggressive': (moods: ['angry'], energy: 'high'),
  'dark': (moods: ['dark'], energy: null),
  'uplifting': (moods: ['uplifting'], energy: null),
  'motivational': (moods: ['uplifting'], energy: null),
  'nostalgic': (moods: ['nostalgic'], energy: null),
  'throwback': (moods: ['nostalgic'], energy: null),
  'dreamy': (moods: ['dreamy'], energy: null),
  'party': (moods: ['party'], energy: null),
  'focus': (moods: ['focus'], energy: null),
  'study': (moods: ['focus'], energy: null),
  'studying': (moods: ['focus'], energy: null),
  'work': (moods: ['focus'], energy: null),
  'gym': (moods: ['energetic'], energy: 'high'),
  'workout': (moods: ['energetic'], energy: 'high'),
  'running': (moods: ['energetic'], energy: 'high'),
  'sleep': (moods: ['calm'], energy: 'low'),
  'melancholy': (moods: ['sad'], energy: null),
};

/// Words that don't change what's meant, such as "songs" in "chill songs".
const Set<String> _filler = {
  'songs',
  'song',
  'music',
  'tracks',
  'vibes',
  'vibe',
  'mood',
  'some',
  'and',
  'for',
  'a',
  'to',
  'me',
  'very',
  'really',
  'something',
  'stuff',
  'playlist',
};

/// Filters for a search made only of mood words, like "happy" or "chill songs", so it
/// needs no AI call. Null when any word is something else, such as a name.
SearchFilters? filtersForWords(String text) {
  final words = text.toLowerCase().split(RegExp(r'[^a-z]+'))
    ..removeWhere((word) => word.isEmpty);
  final moods = <String>[];
  String? energy;
  for (final word in words) {
    if (_filler.contains(word)) continue;
    final vibe = _vibes[word];
    if (vibe == null) return null;
    for (final mood in vibe.moods) {
      if (!moods.contains(mood)) moods.add(mood);
    }
    energy ??= vibe.energy;
  }
  if (moods.isEmpty && energy == null) return null;
  return SearchFilters(moods: moods, energy: energy);
}

/// A heading for songs found by mood, such as "Feels happy".
String vibeHeading(SearchFilters filters) {
  if (filters.moods.isNotEmpty) return 'Feels ${filters.moods.first}';
  if (filters.energy case final energy?) {
    return '${_capitalised(energy)} energy';
  }
  return 'Matches the mood';
}

String _capitalised(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';
