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
