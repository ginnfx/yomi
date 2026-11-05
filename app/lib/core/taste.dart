import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// How much liking an artist counts next to liking the song itself.
const double _artistShare = 0.5;

/// Every this-many places, a song the person hasn't shown a liking for yet, so results
/// still bring something new.
const int _freshEvery = 4;

/// What one person seems to like, built from their own plays, likes and imported history.
@immutable
class TasteProfile {
  const TasteProfile({this.songs = const {}, this.artists = const {}});

  static const empty = TasteProfile();

  /// Score per song ID. Skips make it negative.
  final Map<String, double> songs;

  /// Score per artist name.
  final Map<String, double> artists;

  bool get isEmpty => songs.isEmpty && artists.isEmpty;

  double of(Song song) =>
      (songs[song.id] ?? 0) + (artists[song.artist.trim()] ?? 0) * _artistShare;
}

/// Up to [take] of [songs], favourites first, with a new one every few places and songs
/// this person keeps skipping last. Without any taste yet, a plain shuffle.
List<Song> orderByTaste(
  List<Song> songs,
  TasteProfile taste,
  Random random, {
  required int take,
}) {
  if (taste.isEmpty) return ([...songs]..shuffle(random)).take(take).toList();
  final scores = {for (final song in songs) song.id: taste.of(song)};
  final jitter = {
    for (final song in songs) song.id: 0.7 + random.nextDouble() * 0.6,
  };
  double rank(Song song) => scores[song.id]! * jitter[song.id]!;
  final liked = [
    for (final song in songs)
      if (scores[song.id]! > 0) song,
  ]..sort((a, b) => rank(b).compareTo(rank(a)));
  final fresh = [
    for (final song in songs)
      if (scores[song.id] == 0) song,
  ]..shuffle(random);
  final disliked = [
    for (final song in songs)
      if (scores[song.id]! < 0) song,
  ]..sort((a, b) => scores[b.id]!.compareTo(scores[a.id]!));
  final ordered = <Song>[];
  var nextLiked = 0;
  var nextFresh = 0;
  while (ordered.length < take &&
      (nextLiked < liked.length || nextFresh < fresh.length)) {
    final isFreshTurn = (ordered.length + 1) % _freshEvery == 0;
    final useFresh =
        nextFresh < fresh.length && (isFreshTurn || nextLiked >= liked.length);
    ordered.add(useFresh ? fresh[nextFresh++] : liked[nextLiked++]);
  }
  return [...ordered, ...disliked].take(take).toList();
}
