import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/ui/library/library_items.dart';

const _roadTrip = Playlist(
  id: 'p1',
  name: 'Road trip',
  songCount: 10,
  durationSeconds: 2400,
);
const _ambient = Playlist(
  id: 'p2',
  name: 'ambient',
  songCount: 4,
  durationSeconds: 900,
  owner: 'keli',
);
const _bleach = Playlist(
  id: 'p3',
  name: 'Bleach OST',
  songCount: 30,
  durationSeconds: 5400,
);
const _artist = Artist(id: 'a1', name: 'Dave', albumCount: 2);
const _imported = ImportedPlaylist(
  id: 'i1',
  name: 'Instagram Saved Music',
  entries: [],
);

List<LibraryItem> _build({
  LibraryFilter? filter,
  String query = '',
  LibrarySort sort = LibrarySort.custom,
  Set<String> kept = const {},
  int downloadedCount = 0,
}) => buildLibraryItems(
  filter: filter,
  query: query,
  sort: sort,
  me: 'ginnfx',
  playlists: const [_roadTrip, _ambient, _bleach],
  imported: const [_imported],
  artists: const [_artist],
  isKept: (playlist) => kept.contains(playlist.id),
  downloadedCount: downloadedCount,
);

List<String> _titles(List<LibraryItem> items) => [
  for (final item in items) item.title,
];

void main() {
  group('buildLibraryItems', () {
    test(
      'shows Liked songs first, then imports and playlists, but no artists',
      () {
        final items = _build();

        expect(_titles(items), [
          'Liked songs',
          'Instagram Saved Music',
          'Road trip',
          'ambient',
          'Bleach OST',
        ]);
      },
    );

    test('pins Downloaded songs under Liked songs once something is saved', () {
      final items = _build(downloadedCount: 3);

      expect(_titles(items).take(2), ['Liked songs', 'Downloaded songs']);
      expect((items[1] as DownloadedSongsItem).count, 3);
    });

    test('the Artists chip shows only artists', () {
      expect(_titles(_build(filter: LibraryFilter.artists)), ['Dave']);
    });

    test('the Downloaded chip shows saved songs and kept playlists only', () {
      final items = _build(filter: LibraryFilter.downloaded, kept: {'p3'});

      expect(_titles(items), ['Downloaded songs', 'Bleach OST']);
      expect((items[1] as PlaylistItem).isKept, isTrue);
    });

    test('searching with no chip also finds artists', () {
      expect(_titles(_build(query: 'dav')), ['Dave']);
    });

    test('searching hides pinned rows that do not match', () {
      expect(_titles(_build(query: 'road')), ['Road trip']);
    });

    test('alphabetical ignores case and keeps pinned rows on top', () {
      final items = _build(sort: LibrarySort.alphabetical);

      expect(_titles(items), [
        'Liked songs',
        'ambient',
        'Bleach OST',
        'Instagram Saved Music',
        'Road trip',
      ]);
    });

    test('by creator groups playlists by who made them', () {
      final items = _build(sort: LibrarySort.creator);

      expect(_titles(items), [
        'Liked songs',
        'Bleach OST',
        'Road trip',
        'ambient',
        'Instagram Saved Music',
      ]);
    });

    test('a playlist with no owner is shown as yours', () {
      final roadTrip = _build().whereType<PlaylistItem>().first;

      expect(roadTrip.owner, 'ginnfx');
    });
  });

  test('an unknown saved sort falls back to the custom order', () {
    expect(LibrarySort.byName('recents'), LibrarySort.custom);
    expect(LibrarySort.byName(null), LibrarySort.custom);
    expect(LibrarySort.byName('creator'), LibrarySort.creator);
  });
}
