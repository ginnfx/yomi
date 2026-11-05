import '../models.dart';
import '../search_index.dart';
import '../spotify/spotify_export.dart';

const int _minPlays = 5;
const int _maxPerYear = 40;

String _keyOf(String artist, String title) =>
    '${normalizeForSearch(artist)}|${normalizeForSearch(title)}';

/// Songs in your library that you played a lot in past years on Spotify, by year.
Map<int, List<Song>> pastFavourites(
  ImportedHistory imported,
  List<Song> library,
) {
  if (imported.isEmpty || library.isEmpty) return const {};
  final byKey = {
    for (final song in library) _keyOf(song.artist, song.title): song,
  };
  return {
    for (final year in imported.years)
      year: [
        for (final track in imported.topTracks(year))
          if (track.plays >= _minPlays)
            ?byKey[_keyOf(track.artist, track.track)],
      ].take(_maxPerYear).toList(),
  };
}

const int _maxMissing = 30;

/// What you played most on Spotify that isn't in your library, most played first.
List<TrackTotal> missingFavourites(
  ImportedHistory imported,
  List<Song> library,
) {
  if (imported.isEmpty) return const [];
  final owned = {for (final song in library) _keyOf(song.artist, song.title)};
  final totals = <String, TrackTotal>{};
  for (final year in imported.years) {
    for (final track in imported.topTracks(year)) {
      final key = _keyOf(track.artist, track.track);
      if (owned.contains(key)) continue;
      final current = totals[key];
      totals[key] = current == null
          ? track
          : TrackTotal(
              track: track.track,
              artist: track.artist,
              plays: current.plays + track.plays,
              ms: current.ms + track.ms,
            );
    }
  }
  return (totals.values.where((track) => track.plays >= _minPlays).toList()
        ..sort((a, b) => b.plays.compareTo(a.plays)))
      .take(_maxMissing)
      .toList();
}
