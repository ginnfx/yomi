import 'dart:math';

import 'ai/ai_api.dart';
import 'models.dart';

/// How many songs a radio adds at a time.
const int kRadioLength = 20;

/// Most songs by one artist in a radio, so it stays varied.
const int kRadioPerArtist = 3;

const double _sameArtist = 2;
const double _similarArtist = 3;
const double _sharedMood = 1;
const double _sameEnergy = 1;
const double _sameGenre = 1;

/// "Play similar": library songs like [seed], from its labels, similar artists and genre,
/// without asking the AI for each song. Empty when nothing is related, so the caller can
/// fall back to something else.
List<Song> radioFrom(
  Song seed, {
  required List<Song> library,
  required SongTag? Function(Song song) tagFor,
  required Map<String, List<String>> similarArtists,
  Set<String> exclude = const {},
  int length = kRadioLength,
}) {
  final seedTag = tagFor(seed);
  final seedArtist = seed.artist.trim();
  final similar = (similarArtists[seedArtist] ?? const []).toSet();
  final seedGenre = seed.genre?.toLowerCase();
  // Ties are broken the same way every time for this seed, so suggestions stay put.
  final order = Random(seed.id.hashCode);
  final scored = <(Song, double, double)>[];
  for (final song in library) {
    if (song.id == seed.id || exclude.contains(song.id) || song.isFromYoutube) {
      continue;
    }
    final artist = song.artist.trim();
    var score = 0.0;
    if (artist == seedArtist) score += _sameArtist;
    if (similar.contains(artist)) score += _similarArtist;
    final tag = tagFor(song);
    if (seedTag != null && tag != null) {
      score += _sharedMood * tag.moods.where(seedTag.moods.contains).length;
      if (seedTag.energy != null && tag.energy == seedTag.energy) {
        score += _sameEnergy;
      }
    }
    if (seedGenre != null && song.genre?.toLowerCase() == seedGenre) {
      score += _sameGenre;
    }
    if (score > 0) scored.add((song, score, order.nextDouble()));
  }
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    return byScore != 0 ? byScore : a.$3.compareTo(b.$3);
  });
  final perArtist = <String, int>{};
  final radio = <Song>[];
  for (final (song, _, _) in scored) {
    final artist = song.artist.trim();
    if ((perArtist[artist] ?? 0) >= kRadioPerArtist) continue;
    perArtist[artist] = (perArtist[artist] ?? 0) + 1;
    radio.add(song);
    if (radio.length >= length) break;
  }
  return List.unmodifiable(radio);
}
