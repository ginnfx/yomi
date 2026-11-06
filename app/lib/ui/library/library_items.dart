import '../../core/models.dart';
import '../../core/spotify/imported_playlist.dart';

/// The chips under "Your Library". None selected shows everything but artists.
enum LibraryFilter {
  playlists('Playlists'),
  artists('Artists'),
  downloaded('Downloaded');

  const LibraryFilter(this.label);

  final String label;
}

/// How the library is ordered. Pinned rows (Liked songs, downloads) always stay on top.
enum LibrarySort {
  custom('Custom order'),
  alphabetical('Alphabetical'),
  creator('Creator');

  const LibrarySort(this.label);

  final String label;

  static LibrarySort byName(String? name) => values.firstWhere(
    (sort) => sort.name == name,
    orElse: () => LibrarySort.custom,
  );
}

/// One row of the library.
sealed class LibraryItem {
  const LibraryItem();

  String get title;

  /// Who made it, for sorting by creator.
  String get creator;

  bool get isPinned => false;
}

final class LikedSongsItem extends LibraryItem {
  const LikedSongsItem(this.owner);

  final String owner;

  @override
  String get title => 'Liked songs';

  @override
  String get creator => owner;

  @override
  bool get isPinned => true;
}

final class DownloadedSongsItem extends LibraryItem {
  const DownloadedSongsItem(this.count);

  final int count;

  @override
  String get title => 'Downloaded songs';

  @override
  String get creator => '';

  @override
  bool get isPinned => true;
}

final class PlaylistItem extends LibraryItem {
  const PlaylistItem(this.playlist, {required this.owner, this.isKept = false});

  final Playlist playlist;
  final String owner;

  /// Kept on this device by "Keep offline".
  final bool isKept;

  @override
  String get title => playlist.name;

  @override
  String get creator => owner;
}

final class ImportedItem extends LibraryItem {
  const ImportedItem(this.playlist);

  final ImportedPlaylist playlist;

  @override
  String get title => playlist.name;

  @override
  String get creator => 'Spotify';
}

final class ArtistItem extends LibraryItem {
  const ArtistItem(this.artist);

  final Artist artist;

  @override
  String get title => artist.name;

  @override
  String get creator => artist.name;
}

bool _matches(String text, String query) =>
    query.isEmpty || text.toLowerCase().contains(query.toLowerCase());

/// Everything the library shows for a filter, search and order.
///
/// [playlists] arrive already in the user's custom order. Artists only appear under
/// their own chip, or when searching: a whole library's artists would bury the
/// playlists. Downloaded shows saved songs and the playlists kept offline.
List<LibraryItem> buildLibraryItems({
  required LibraryFilter? filter,
  required String query,
  required LibrarySort sort,
  required String me,
  required List<Playlist> playlists,
  required List<ImportedPlaylist> imported,
  required List<Artist> artists,
  required bool Function(Playlist playlist) isKept,
  required int downloadedCount,
}) {
  final showsPlaylists =
      filter == null ||
      filter == LibraryFilter.playlists ||
      filter == LibraryFilter.downloaded;
  final onlyKept = filter == LibraryFilter.downloaded;
  final showsArtists =
      filter == LibraryFilter.artists || (filter == null && query.isNotEmpty);
  final pinned = <LibraryItem>[
    if (filter == null || filter == LibraryFilter.playlists) LikedSongsItem(me),
    if (filter == LibraryFilter.downloaded ||
        (filter == null && downloadedCount > 0))
      DownloadedSongsItem(downloadedCount),
  ];
  final rest = <LibraryItem>[
    if (showsPlaylists && !onlyKept) ...imported.map(ImportedItem.new),
    if (showsPlaylists)
      for (final playlist in playlists)
        if (!onlyKept || isKept(playlist))
          PlaylistItem(
            playlist,
            owner: playlist.owner ?? me,
            isKept: isKept(playlist),
          ),
    if (showsArtists) ...artists.map(ArtistItem.new),
  ];
  final sorted = switch (sort) {
    LibrarySort.custom => rest,
    LibrarySort.alphabetical => [...rest]..sort(_byTitle),
    LibrarySort.creator =>
      [...rest]..sort(
        (a, b) => _compareText(a.creator, b.creator) != 0
            ? _compareText(a.creator, b.creator)
            : _byTitle(a, b),
      ),
  };
  return [
    for (final item in [...pinned, ...sorted])
      if (_matches(item.title, query)) item,
  ];
}

int _compareText(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

int _byTitle(LibraryItem a, LibraryItem b) => _compareText(a.title, b.title);
