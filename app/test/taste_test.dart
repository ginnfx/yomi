import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/recommendations.dart';
import 'package:yomi/core/taste.dart';

Song song(int i, {String artist = 'Artist'}) => Song(
  id: 's$i',
  title: 'Song $i',
  artist: artist,
  album: 'Album',
  durationSeconds: 100,
);

void main() {
  final now = DateTime(2026, 11, 5, 20);

  group('TasteProfile', () {
    test('scores a song by its own plays and by liking its artist', () {
      const taste = TasteProfile(songs: {'s1': 3}, artists: {'Nujabes': 2});
      expect(taste.of(song(1)), greaterThan(taste.of(song(2))));
      expect(taste.of(song(2, artist: 'Nujabes')), greaterThan(0));
      expect(taste.of(song(3)), 0);
      expect(TasteProfile.empty.isEmpty, isTrue);
    });
  });

  group('orderByTaste', () {
    final library = [
      for (var i = 0; i < 40; i++) song(i, artist: i < 10 ? 'Liked' : 'Other'),
    ];

    test('puts what this person likes first, with something new mixed in', () {
      const taste = TasteProfile(artists: {'Liked': 5});
      final ordered = orderByTaste(library, taste, Random(1), take: 12);
      expect(ordered, hasLength(12));
      final firstThree = ordered.take(3).map((s) => s.artist);
      expect(firstThree, everyElement('Liked'));
      expect(ordered.map((s) => s.artist), contains('Other'));
      expect(ordered.toSet(), hasLength(12));
    });

    test('two people get different results for the same search', () {
      const mine = TasteProfile(artists: {'Liked': 5});
      const friends = TasteProfile(artists: {'Other': 5});
      final forMe = orderByTaste(library, mine, Random(1), take: 6);
      final forFriend = orderByTaste(library, friends, Random(1), take: 6);
      expect(forMe.first.artist, 'Liked');
      expect(forFriend.first.artist, 'Other');
    });

    test('songs someone keeps skipping go last', () {
      final taste = TasteProfile(songs: {'s5': -4}, artists: const {});
      final ordered = orderByTaste(
        library.take(6).toList(),
        taste,
        Random(2),
        take: 6,
      );
      expect(ordered.last.id, 's5');
    });

    test('with no listening yet it is a plain shuffle of the matches', () {
      final ordered = orderByTaste(
        library,
        TasteProfile.empty,
        Random(3),
        take: 10,
      );
      expect(ordered, hasLength(10));
      expect(ordered.every(library.contains), isTrue);
    });

    test('does not change the list it was given', () {
      final input = List<Song>.unmodifiable(library);
      orderByTaste(
        input,
        const TasteProfile(artists: {'Liked': 1}),
        Random(4),
        take: 5,
      );
      expect(input.first.id, 's0');
    });
  });

  test(
    'Home exposes the taste it built from plays, likes and Spotify history',
    () {
      final pool = [
        song(1, artist: 'A'),
        song(2, artist: 'B'),
        song(3, artist: 'C'),
      ];
      final taste = HomeBuilder(
        events: [
          for (var i = 0; i < 3; i++)
            PlayEvent(
              's1',
              now.subtract(Duration(hours: i)),
              PlayKind.completed,
            ),
        ],
        pool: pool,
        recentlyAdded: const [],
        now: now,
        starred: const {'s2'},
        importedTaste: const {'C': 50},
      ).taste();
      expect(taste.of(pool[0]), greaterThan(0));
      expect(taste.of(pool[1]), greaterThan(0));
      expect(taste.of(pool[2]), greaterThan(0));
      expect(taste.of(song(9, artist: 'Nobody')), 0);
    },
  );
}
