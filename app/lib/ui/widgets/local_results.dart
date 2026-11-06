import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/search_index.dart';
import '../../state/catalog_controller.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../pages/collection_page.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'send_to_sheet.dart';

/// Library matches for a search: the top result, artists and albums.
class LocalResults extends StatelessWidget {
  const LocalResults({required this.results, required this.onOpened});

  final IndexedResults results;
  final VoidCallback onOpened;

  void _openArtist(BuildContext context, ArtistResult artist) {
    final songs = context.read<CatalogController>().songs;
    onOpened();
    Navigator.of(context).push(
      yomiRoute<void>(
        builder: (_) => CollectionPage(
          title: artist.name,
          subtitle: '',
          coverArtId: artist.coverArtId,
          kind: CollectionKind.artist,
          loadSongs: () async => [
            for (final song in songs)
              if (song.artist == artist.name) song,
          ],
        ),
      ),
    );
  }

  void _openAlbum(BuildContext context, AlbumResult album) {
    final client = context.read<SessionController>().client;
    onOpened();
    Navigator.of(context).push(
      yomiRoute<void>(
        builder: (_) => CollectionPage(
          title: album.name,
          subtitle: album.artist,
          coverArtId: album.coverArtId,
          savedSongs: client.cachedAlbumSongs(album.id),
          kind: CollectionKind.album,
          loadSongs: () => client.albumSongs(album.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = results.topResult;
    final player = context.read<PlayerController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (top is SongMatch)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: kPagePadding,
            ),
            leading: CoverArt(
              coverArtId: top.song.coverArtId,
              size: 64,
              radius: YomiRadius.art,
              seed: top.song.album,
            ),
            title: Text(
              top.song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(18, weight: FontWeight.w800),
            ),
            subtitle: Text(
              'Top result · ${top.song.artist}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              onOpened();
              player.playQueue(results.songs);
            },
          ),
        for (final artist in results.artists)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: kPagePadding,
            ),
            leading: const Icon(Icons.person_rounded),
            title: Text(
              artist.name,
              style: yomiText(15, weight: FontWeight.w700),
            ),
            subtitle: Text('Artist · ${artist.songCount} songs'),
            onTap: () => _openArtist(context, artist),
          ),
        for (final album in results.albums)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: kPagePadding,
            ),
            leading: CoverArt(
              coverArtId: album.coverArtId,
              size: 44,
              radius: YomiRadius.art,
              seed: album.name,
            ),
            title: Text(
              album.name,
              style: yomiText(15, weight: FontWeight.w700),
            ),
            subtitle: Text('Album · ${album.artist}'),
            onTap: () => _openAlbum(context, album),
            onLongPress: () => showSendTo(
              context,
              title: '${album.name} · ${album.artist}',
              albumId: album.id,
            ),
          ),
      ],
    );
  }
}
