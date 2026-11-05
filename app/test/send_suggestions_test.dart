import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/messaging/send_suggestions.dart';
import 'package:yomi/core/models.dart';

Song song(String id) => Song(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  album: 'Album',
  durationSeconds: 100,
);

void main() {
  final library = {
    for (final id in ['a', 'b', 'c', 'd']) id: song(id),
  };
  final now = DateTime(2026, 11, 5, 21);
  PlayEvent play(String id, int minutesAgo) => PlayEvent(
    id,
    now.subtract(Duration(minutes: minutesAgo)),
    PlayKind.completed,
  );

  test('the playing song comes first, then recent plays newest first', () {
    final songs = recentToSend(
      events: [play('a', 30), play('b', 10), play('c', 20)],
      songFor: (id) => library[id],
      nowPlaying: library['d'],
    );
    expect(songs.map((s) => s.id), ['d', 'b', 'c', 'a']);
  });

  test('each song appears once, even when played many times', () {
    final songs = recentToSend(
      events: [play('a', 1), play('a', 2), play('b', 3), play('a', 4)],
      songFor: (id) => library[id],
      nowPlaying: library['a'],
    );
    expect(songs.map((s) => s.id), ['a', 'b']);
  });

  test(
    'songs no longer in the library are left out, and the list is capped',
    () {
      final songs = recentToSend(
        events: [play('gone', 1), for (var i = 0; i < 5; i++) play('b', i + 2)],
        songFor: (id) => library[id],
        max: 1,
      );
      expect(songs.map((s) => s.id), ['b']);
    },
  );
}
