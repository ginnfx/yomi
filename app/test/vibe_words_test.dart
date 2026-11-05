import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/ai/vibe_words.dart';

void main() {
  test('a single mood word becomes that mood', () {
    final filters = filtersForWords('happy')!;
    expect(filters.moods, ['happy']);
    expect(filters.energy, isNull);
  });

  test('everyday words map onto the moods the AI uses', () {
    expect(filtersForWords('chill')!.moods, ['calm']);
    expect(filtersForWords('Chill songs')!.moods, ['calm']);
    expect(filtersForWords('love songs')!.moods, ['romantic']);
    expect(filtersForWords('study music')!.moods, ['focus']);
  });

  test('activity words also set the energy', () {
    final gym = filtersForWords('gym')!;
    expect(gym.energy, 'high');
    expect(gym.moods, contains('energetic'));
    expect(filtersForWords('sleep')!.energy, 'low');
  });

  test('several vibe words combine without repeats', () {
    final filters = filtersForWords('sad and dreamy vibes')!;
    expect(filters.moods, ['sad', 'dreamy']);
  });

  test('anything else is left to title search and the AI', () {
    expect(filtersForWords('happy beatles'), isNull);
    expect(filtersForWords('Bohemian Rhapsody'), isNull);
    expect(filtersForWords('songs'), isNull);
    expect(filtersForWords('   '), isNull);
  });

  test('moods to offer as chips are the AI moods, in a friendly order', () {
    expect(kVibeChips, contains('happy'));
    expect(kVibeChips, contains('focus'));
    expect(kVibeChips.toSet(), hasLength(kVibeChips.length));
  });

  test('each mood has a heading to show above its songs', () {
    expect(vibeHeading(filtersForWords('happy')!), 'Feels happy');
    expect(vibeHeading(filtersForWords('gym')!), 'Feels energetic');
  });
}
