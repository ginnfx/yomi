import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/mixes.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/taste.dart';

Song song(int i, String artist) => Song(
  id: 's$i',
  title: 'Song $i',
  artist: artist,
  album: 'Album',
  durationSeconds: 100,
);

void main() {
  // 0-19 calm by Nujabes, 20-39 party by Future, 40-59 sad by Adele.
  final library = [
    for (var i = 0; i < 20; i++) song(i, 'Nujabes'),
    for (var i = 20; i < 40; i++) song(i, 'Future'),
    for (var i = 40; i < 60; i++) song(i, 'Adele'),
  ];
  SongTag? tagFor(Song s) {
    final n = int.parse(s.id.substring(1));
    return SongTag(moods: [n < 20 ? 'calm' : (n < 40 ? 'party' : 'sad')]);
  }

  group('suggestMixes', () {
    test('makes a mix for each mood this person likes most', () {
      const taste = TasteProfile(artists: {'Nujabes': 5, 'Adele': 2});
      final mixes = suggestMixes(
        library: library,
        taste: taste,
        tagFor: tagFor,
        random: Random(1),
      );
      expect(mixes.map((m) => m.moods.single), ['calm', 'sad']);
      expect(mixes.first.songs.every((s) => s.artist == 'Nujabes'), isTrue);
      expect(mixes.first.artists, ['Nujabes']);
      expect(mixes.first.request.moods, ['calm']);
    });

    test('nothing to suggest without taste or labels', () {
      expect(
        suggestMixes(
          library: library,
          taste: TasteProfile.empty,
          tagFor: tagFor,
          random: Random(1),
        ),
        isEmpty,
      );
      expect(
        suggestMixes(
          library: library,
          taste: const TasteProfile(artists: {'Nujabes': 5}),
          tagFor: (_) => null,
          random: Random(1),
        ),
        isEmpty,
      );
    });
  });

  group('blend', () {
    test('mixes both tastes, shared favourites first', () {
      const mine = TasteProfile(artists: {'Nujabes': 5, 'Adele': 3});
      final songs = blendSongs(
        library: library,
        mine: mine,
        theirArtists: const ['Adele', 'Future'],
        random: Random(2),
        size: 20,
      );
      expect(songs, hasLength(20));
      expect(songs.first.artist, 'Adele');
      final artists = songs.map((s) => s.artist).toSet();
      expect(artists, containsAll(['Nujabes', 'Adele', 'Future']));
      expect(songs.map((s) => s.id).toSet(), hasLength(20));
    });
  });

  group('taste match', () {
    test('the same taste is 100, nothing shared is 0', () {
      expect(
        tasteMatch(
          myArtists: ['A', 'B'],
          theirArtists: ['B', 'A'],
          myMoods: ['calm'],
          theirMoods: ['calm'],
        ),
        100,
      );
      expect(
        tasteMatch(
          myArtists: ['A'],
          theirArtists: ['B'],
          myMoods: ['calm'],
          theirMoods: ['party'],
        ),
        0,
      );
    });

    test('partial overlap lands in between, unknown taste is null', () {
      final match = tasteMatch(
        myArtists: ['A', 'B', 'C', 'D'],
        theirArtists: ['A', 'X', 'Y', 'Z'],
        myMoods: ['calm', 'sad'],
        theirMoods: ['calm'],
      )!;
      expect(match, inExclusiveRange(0, 100));
      expect(
        tasteMatch(
          myArtists: const [],
          theirArtists: ['A'],
          myMoods: const [],
          theirMoods: const [],
        ),
        isNull,
      );
    });
  });

  test('top artists and moods to share come from the taste', () {
    const taste = TasteProfile(
      artists: {'Adele': 1, 'Nujabes': 9, 'Future': 4},
    );
    expect(topArtistsOf(taste, count: 2), ['Nujabes', 'Future']);
    expect(
      topMoodsOf(library: library, taste: taste, tagFor: tagFor, count: 1),
      ['calm'],
    );
  });

  test('similar songs to add come from the same and related artists', () {
    final playlist = library.take(3).toList();
    final add = similarToAdd(
      playlist: playlist,
      library: library,
      taste: TasteProfile.empty,
      tagFor: tagFor,
      similarArtists: const {
        'Nujabes': ['Adele'],
      },
      random: Random(3),
      count: 30,
    );
    expect(add.any(playlist.contains), isFalse);
    expect(add.map((s) => s.artist).toSet(), {'Nujabes', 'Adele'});
    expect(add.first.artist, 'Nujabes');
  });
}
