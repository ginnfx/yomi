import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/spotify/imported_playlist.dart';
import '../../state/catalog_controller.dart';
import '../../state/imports_controller.dart';
import '../../state/player_controller.dart';
import '../theme.dart';
import '../widgets/song_tile.dart';

/// Where to look for a song that isn't in the library.
Uri youtubeSearchFor(String artist, String title) => Uri.https(
  'www.youtube.com',
  '/results',
  {'search_query': '$artist $title'},
);

/// An imported playlist in its exact order, with empty places for songs you don't have.
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
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            playlist.name,
            style: yomiText(18, weight: FontWeight.w800),
          ),
          actions: [
            IconButton(
              tooltip: 'Delete playlist',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _delete(context, playlist),
            ),
          ],
        ),
        body: ListView.builder(
          itemCount: playlist.entries.length + 1,
          itemBuilder: (context, row) {
            if (row == 0) {
              return Padding(
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
                    const Spacer(),
                    Text(
                      '${queue.length} of ${playlist.entries.length} in your library',
                      style: yomiText(
                        12.5,
                        weight: FontWeight.w600,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            }
            final i = row - 1;
            final song = songs[i];
            if (song != null) {
              return SongTile(
                key: ValueKey('$i-${song.id}'),
                song: song,
                onTap: () =>
                    player.playQueue(queue, startIndex: queue.indexOf(song)),
              );
            }
            return _MissingTrack(entry: playlist.entries[i]);
          },
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
        trailing: IconButton(
          tooltip: 'Find on YouTube',
          icon: const Icon(Icons.open_in_new_rounded),
          onPressed: () => launchUrl(
            youtubeSearchFor(entry.artist, entry.title),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    );
  }
}
