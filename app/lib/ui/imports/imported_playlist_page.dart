import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/spotify/imported_playlist.dart';
import '../../state/catalog_controller.dart';
import '../../state/imports_controller.dart';
import '../../state/player_controller.dart';
import '../../state/playlist_covers_controller.dart';
import '../pages/reorder_page.dart';
import '../theme.dart';
import '../widgets/add_songs_sheet.dart';
import '../widgets/youtube_play_button.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/playlist_recommendations.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/song_tile.dart';

/// How big the cover is at the top of the page.
const double _heroCover = 220;

/// An imported playlist in its exact order, with empty places for songs you don't have.
/// Otherwise it works like any playlist: rename it, give it a picture, reorder, add.
class ImportedPlaylistPage extends StatelessWidget {
  const ImportedPlaylistPage({super.key, required this.playlistId});

  final String playlistId;

  Future<void> _delete(BuildContext context, ImportedPlaylist playlist) async {
    final navigator = Navigator.of(context);
    final imports = context.read<ImportsController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete "${playlist.name}"?'),
        content: const Text('The songs stay in your library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    navigator.pop();
    await imports.remove(playlist.id);
  }

  Future<void> _rename(BuildContext context, ImportedPlaylist playlist) async {
    final imports = context.read<ImportsController>();
    final name = await promptForName(
      context,
      title: 'Rename playlist',
      initial: playlist.name,
    );
    if (name == null || name.trim().isEmpty) return;
    await imports.update(playlist.renamed(name.trim()));
  }

  Future<void> _reorder(
    BuildContext context,
    ImportedPlaylist playlist,
    Map<String, Song> byId,
  ) async {
    final imports = context.read<ImportsController>();
    final order = await reorderSongs(
      context,
      title: playlist.name,
      items: [
        for (final entry in playlist.entries)
          ReorderItem(
            title: entry.title,
            subtitle: entry.artist,
            coverArtId: byId[entry.songId]?.coverArtId,
          ),
      ],
    );
    if (order == null) return;
    await imports.update(
      playlist.withEntries([for (final i in order) playlist.entries[i]]),
    );
  }

  Future<void> _add(
    BuildContext context,
    ImportedPlaylist playlist,
    Song song,
  ) => context.read<ImportsController>().update(playlist.withSongAdded(song));

  @override
  Widget build(BuildContext context) {
    final imports = context.watch<ImportsController>();
    final playlist = imports.playlists
        .where((p) => p.id == playlistId)
        .firstOrNull;
    if (playlist == null) return const Scaffold();
    final byId = {
      for (final song in context.watch<CatalogController>().songs)
        song.id: song,
    };
    final songs = <int, Song>{
      for (final (i, entry) in playlist.entries.indexed)
        if (byId[entry.songId] case final song?) i: song,
    };
    final queue = songs.values.toList(growable: false);
    final player = context.read<PlayerController>();
    final hasPicture = context.watch<PlaylistCoversController>().hasCover(
      playlist.id,
    );
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          actions: [
            PopupMenuButton<String>(
              onSelected: (value) => switch (value) {
                'rename' => _rename(context, playlist),
                'picture' => pickPlaylistPicture(context, playlist.id),
                'removePicture' =>
                  context.read<PlaylistCoversController>().removeCover(
                    playlist.id,
                  ),
                'order' => _reorder(context, playlist, byId),
                _ => _delete(context, playlist),
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                const PopupMenuItem(
                  value: 'picture',
                  child: Text('Choose picture'),
                ),
                if (hasPicture)
                  const PopupMenuItem(
                    value: 'removePicture',
                    child: Text('Remove picture'),
                  ),
                if (playlist.entries.length > 1)
                  const PopupMenuItem(
                    value: 'order',
                    child: Text('Change order'),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete playlist'),
                ),
              ],
            ),
          ],
        ),
        body: ListView(
          children: [
            Center(
              child: PlaylistCover(
                playlistId: playlist.id,
                coverArtId: queue.firstOrNull?.coverArtId,
                size: _heroCover,
                radius: 20,
                elevated: true,
                seed: playlist.name,
                onPick: () => pickPlaylistPicture(context, playlist.id),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                20,
                kPagePadding,
                4,
              ),
              child: Text(
                playlist.name,
                style: yomiText(
                  26,
                  weight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
              child: Text(
                queue.length == playlist.entries.length
                    ? '${playlist.entries.length} songs · From Spotify'
                    : '${playlist.entries.length} songs · '
                          '${playlist.entries.length - queue.length} not in '
                          'your library yet',
                style: yomiText(13, color: YomiColors.textSecondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(kPagePadding),
              child: Row(
                children: [
                  FilledButton.icon(
                    onPressed: queue.isEmpty
                        ? null
                        : () => player.playQueue(queue),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Play'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: queue.isEmpty
                        ? null
                        : () async {
                            await player.playQueue(queue);
                            if (!player.isShuffled) {
                              await player.toggleShuffle();
                            }
                          },
                    icon: const Icon(Icons.shuffle_rounded),
                    label: const Text('Shuffle'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                0,
                kPagePadding,
                kPagePadding,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AddChip(
                  onTap: () => showAddSongsSheet(
                    context,
                    playlistName: playlist.name,
                    playlistSongs: queue,
                    onAdd: (song) => _add(context, playlist, song),
                  ),
                ),
              ),
            ),
            for (final (i, entry) in playlist.entries.indexed)
              if (songs[i] case final song?)
                SongTile(
                  key: ValueKey('$i-${song.id}'),
                  song: song,
                  onTap: () =>
                      player.playQueue(queue, startIndex: queue.indexOf(song)),
                )
              else
                _MissingTrack(entry: entry),
            PlaylistRecommendations(
              key: ValueKey('recommended-${playlist.id}'),
              songs: queue,
              onAdd: (song) => _add(context, playlist, song),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _MissingTrack extends StatelessWidget {
  const _MissingTrack({required this.entry});

  final ImportEntry entry;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.5,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: kPagePadding),
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          "${entry.artist} · Not in your library",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: YoutubePlayButton(artist: entry.artist, title: entry.title),
      ),
    );
  }
}
