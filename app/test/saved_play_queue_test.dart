import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/saved_play_queue.dart';

void main() {
  test('no saved tracks yields no resume prompt', () {
    expect(SavedPlayQueue.fromJson(null), isNull);
    expect(SavedPlayQueue.fromJson({'entry': []}), isNull);
  });
  test('recovers string song IDs, current index and millisecond position', () {
    final saved = SavedPlayQueue.fromJson({
      'current': 2,
      'position': 12450,
      'changedBy': 'Yomi/macos/unique',
      'changed': '2026-11-02T12:00:00Z',
      'entry': [
        {'id': '1', 'duration': 30},
        {'id': '2', 'duration': 40},
      ],
    })!;
    expect(saved.index, 1);
    expect(saved.position.inMilliseconds, 12450);
    expect(saved.deviceLabel, 'Mac');
    expect(saved.changed, DateTime.utc(2026, 11, 2, 12));
  });
  test('missing songs and out-of-range positions restore safely', () {
    SavedPlayQueue decode(int position) => SavedPlayQueue.fromJson({
      'current': 'removed-song',
      'position': position,
      'entry': [
        {'id': 'remaining', 'duration': 10},
      ],
    })!;
    expect(decode(-100).index, 0);
    expect(decode(-100).position, Duration.zero);
    expect(decode(20000).position.inSeconds, 10);
  });
  test('device labels support OS identifiers used by Dart', () {
    for (final entry in {
      'ios': 'iPhone',
      'macos': 'Mac',
      'android': 'Android',
    }.entries) {
      final saved = SavedPlayQueue.fromJson({
        'entry': [
          {'id': '1'},
        ],
        'changedBy': 'Yomi/${entry.key}/id',
      })!;
      expect(saved.deviceLabel, entry.value);
    }
  });
}
