import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai/ai_api.dart';
import 'models.dart';
import 'taste.dart';

/// How many "Made for you" mixes to suggest, and how long each is.
const int kSuggestedMixes = 4;
const int kMixSize = 25;

/// A mood needs at least this many songs to make a mix.
const int _minMixSongs = 8;

/// How many of a person's favourite songs decide which moods they like.
const int _tasteSample = 200;

/// Artists named with a mix, to help the AI give it a fitting name.
const int _mixArtists = 3;

/// A suggested playlist: songs of one mood, ordered by taste.
@immutable
class SuggestedMix {
  const SuggestedMix({
    required this.moods,
    required this.artists,
    required this.songs,
  });

  final List<String> moods;
  final List<String> artists;
  final List<Song> songs;

  MixRequest get request => MixRequest(moods: moods, artists: artists);

  /// A plain name for when the AI can't give one.
  String get plainName => moods.isEmpty
      ? 'Your mix'
      : '${moods.first[0].toUpperCase()}${moods.first.substring(1)} mix';
}

Map<String, double> _rank(Iterable<MapEntry<String, double>> entries) {
  final totals = <String, double>{};
  for (final entry in entries) {
    totals[entry.key] = (totals[entry.key] ?? 0) + entry.value;
  }
  return totals;
}

List<String> _topKeys(Map<String, double> totals, int count) {
  final entries = totals.entries.where((e) => e.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [for (final entry in entries.take(count)) entry.key];
}

/// This person's favourite songs, best first.
List<Song> _favourites(List<Song> library, TasteProfile taste) {
  final liked = [
    for (final song in library)
      if (taste.of(song) > 0) song,
  ]..sort((a, b) => taste.of(b).compareTo(taste.of(a)));
  return liked.take(_tasteSample).toList();
}

/// The moods this person plays most, best first.
List<String> topMoodsOf({
  required List<Song> library,
  required TasteProfile taste,
  required SongTag? Function(Song) tagFor,
  int count = 5,
}) => _topKeys(
  _rank([
    for (final song in _favourites(library, taste))
      for (final mood in tagFor(song)?.moods ?? const <String>[])
        MapEntry(mood, taste.of(song)),
  ]),
  count,
);

/// The artists this person likes most, best first. This is what friends see.
List<String> topArtistsOf(TasteProfile taste, {int count = 10}) =>
    _topKeys(taste.artists, count);

/// "Made for you": a mix for each of this person's favourite moods.
List<SuggestedMix> suggestMixes({
  required List<Song> library,
  required TasteProfile taste,
  required SongTag? Function(Song) tagFor,
  required Random random,
  int count = kSuggestedMixes,
  int size = kMixSize,
}) {
  if (taste.isEmpty) return const [];
  final mixes = <SuggestedMix>[];
  for (final mood in topMoodsOf(
    library: library,
    taste: taste,
    tagFor: tagFor,
    count: count,
  )) {
    final fits = [
      for (final song in library)
        if (tagFor(song)?.moods.contains(mood) ?? false) song,
    ];
    if (fits.length < _minMixSongs) continue;
    final songs = orderByTaste(fits, taste, random, take: size);
    mixes.add(
      SuggestedMix(
        moods: [mood],
        artists: _topKeys(
          _rank([for (final song in songs) MapEntry(song.artist, 1.0)]),
          _mixArtists,
        ),
        songs: songs,
      ),
    );
  }
  return List.unmodifiable(mixes);
}

/// A Blend: artists you both like first, then your favourites and theirs in turn.
List<Song> blendSongs({
  required List<Song> library,
  required TasteProfile mine,
  required List<String> theirArtists,
  required Random random,
  int size = 30,
}) {
  final theirs = {
    for (var i = 0; i < theirArtists.length; i++)
      theirArtists[i]: (theirArtists.length - i).toDouble(),
  };
  final theirTaste = TasteProfile(artists: theirs);
  final shared = [
    for (final song in library)
      if (theirs.containsKey(song.artist.trim()) && mine.of(song) > 0) song,
  ];
  final sharedFirst = orderByTaste(
    shared,
    TasteProfile(
      artists: {
        for (final artist in theirs.keys)
          artist: (mine.artists[artist] ?? 0) + theirs[artist]!,
      },
    ),
    random,
    take: size ~/ 3,
  );
  final myPicks = orderByTaste(library, mine, random, take: size * 2);
  final theirPicks = orderByTaste(
    [
      for (final song in library)
        if (theirs.containsKey(song.artist.trim())) song,
    ],
    theirTaste,
    random,
    take: size * 2,
  );
  final seen = <String>{};
  final blend = <Song>[];
  void add(Song song) {
    if (blend.length < size && seen.add(song.id)) blend.add(song);
  }

  sharedFirst.forEach(add);
  for (var i = 0; blend.length < size; i++) {
    if (i >= myPicks.length && i >= theirPicks.length) break;
    if (i < myPicks.length) add(myPicks[i]);
    if (i < theirPicks.length) add(theirPicks[i]);
  }
  return List.unmodifiable(blend);
}

/// How alike two tastes are, 0 to 100, mostly from shared artists and a little from
/// shared moods. Null when either person shares nothing.
int? tasteMatch({
  required List<String> myArtists,
  required List<String> theirArtists,
  required List<String> myMoods,
  required List<String> theirMoods,
}) {
  if (myArtists.isEmpty || theirArtists.isEmpty) return null;
  double overlap(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    return a.toSet().intersection(b.toSet()).length / min(a.length, b.length);
  }

  final artists = overlap(myArtists, theirArtists);
  final hasMoods = myMoods.isNotEmpty && theirMoods.isNotEmpty;
  final score = hasMoods
      ? artists * 0.7 + overlap(myMoods, theirMoods) * 0.3
      : artists;
  return (score * 100).round().clamp(0, 100);
}

/// Songs to add to a playlist: by its artists, by artists like them, or of its moods.
List<Song> similarToAdd({
  required List<Song> playlist,
  required List<Song> library,
  required TasteProfile taste,
  required SongTag? Function(Song) tagFor,
  required Map<String, List<String>> similarArtists,
  required Random random,
  int count = 10,
}) {
  final inPlaylist = {for (final song in playlist) song.id};
  final artists = {for (final song in playlist) song.artist};
  final related = {for (final artist in artists) ...?similarArtists[artist]}
      .difference(artists);
  final moods = topMoodsOf(
    library: playlist,
    taste: TasteProfile(songs: {for (final song in playlist) song.id: 1}),
    tagFor: tagFor,
    count: 2,
  ).toSet();
  double fit(Song song) {
    if (artists.contains(song.artist)) return 3;
    if (related.contains(song.artist)) return 2;
    final songMoods = tagFor(song)?.moods ?? const <String>[];
    return songMoods.any(moods.contains) ? 1 : 0;
  }

  final candidates = [
    for (final song in library)
      if (!inPlaylist.contains(song.id) && fit(song) > 0) song,
  ];
  final scores = {
    for (final song in candidates)
      song.id:
          (fit(song) + max(0, taste.of(song))) *
          (0.8 + random.nextDouble() * 0.4),
  };
  candidates.sort((a, b) => scores[b.id]!.compareTo(scores[a.id]!));
  return List.unmodifiable(candidates.take(count));
}
