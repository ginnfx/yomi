import 'models.dart';
import 'taste.dart';

/// The ways the Songs list can be ordered.
enum SongSort {
  recentlyAdded('Recently added'),
  mostPlayed('Most played'),
  forYou('For you'),
  title('Title'),
  artist('Artist');

  const SongSort(this.label);

  final String label;
}

int _byText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

/// [songs] in [sort] order, as a new list. "For you" needs [taste].
List<Song> sortSongs(
  List<Song> songs,
  SongSort sort, {
  TasteProfile taste = TasteProfile.empty,
}) {
  final sorted = [...songs];
  switch (sort) {
    case SongSort.recentlyAdded:
      sorted.sort((a, b) {
        final first = a.addedAt;
        final second = b.addedAt;
        if (first == null || second == null) {
          return (first == null ? 1 : 0) - (second == null ? 1 : 0);
        }
        return second.compareTo(first);
      });
    case SongSort.mostPlayed:
      sorted.sort((a, b) => b.playCount.compareTo(a.playCount));
    case SongSort.forYou:
      final scores = {for (final song in songs) song.id: taste.of(song)};
      sorted.sort((a, b) {
        final byTaste = scores[b.id]!.compareTo(scores[a.id]!);
        return byTaste != 0 ? byTaste : b.playCount.compareTo(a.playCount);
      });
    case SongSort.title:
      sorted.sort((a, b) => _byText(a.title, b.title));
    case SongSort.artist:
      sorted.sort((a, b) {
        final byArtist = _byText(a.artist, b.artist);
        return byArtist != 0 ? byArtist : _byText(a.title, b.title);
      });
  }
  return List.unmodifiable(sorted);
}

/// Only liked songs, or only ones never played. With neither, [songs] itself.
List<Song> filterSongs(
  List<Song> songs, {
  bool likedOnly = false,
  bool unplayedOnly = false,
}) {
  if (!likedOnly && !unplayedOnly) return songs;
  return List.unmodifiable([
    for (final song in songs)
      if ((!likedOnly || song.isStarred) &&
          (!unplayedOnly || song.playCount == 0))
        song,
  ]);
}
