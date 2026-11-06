import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/offline/audio_cache.dart';
import '../../core/offline/audio_files.dart';
import '../../state/catalog_controller.dart';
import '../../state/download_manager.dart';
import '../../state/player_controller.dart';
import '../theme.dart';
import 'song_tile.dart';

bool matchesQuery(String text, String query) =>
    query.isEmpty || text.toLowerCase().contains(query.toLowerCase());

/// Everything saved on this phone. Reads only local data, so it works with no connection.
class DownloadedSongs extends StatelessWidget {
  const DownloadedSongs({this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadManager>();
    final player = context.read<PlayerController>();
    final downloaded = {for (final s in downloads.downloadedSongs) s.id};
    final cachedFiles = context.read<AudioCache>().savedFiles();
    final songs = [
      ...downloads.downloadedSongs,
      // Songs kept from listening play offline too, so they're listed with the rest.
      ...context.watch<CatalogController>().songs.where(
        (s) =>
            !downloaded.contains(s.id) &&
            cachedFiles.containsKey(safeFileId(s.id)),
      ),
    ].where((s) => matchesQuery('${s.title} ${s.artist}', query)).toList();
    if (songs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_circle_down_rounded,
                size: 52,
                color: YomiColors.textSecondary,
              ),
              const SizedBox(height: 14),
              Text(
                'Nothing saved yet',
                style: yomiText(18, weight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'Download with ••• on a song. Songs you play are saved here too.',
                textAlign: TextAlign.center,
                style: yomiText(
                  14,
                  weight: FontWeight.w500,
                  color: YomiColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 6, kPagePadding, 10),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: () => player.playQueue(songs),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  side: BorderSide(color: YomiColors.faint(0.24)),
                ),
                onPressed: () async {
                  await player.playQueue(songs);
                  if (!player.isShuffled) await player.toggleShuffle();
                },
                icon: const Icon(Icons.shuffle_rounded),
                label: Text(
                  'Shuffle',
                  style: yomiText(15, weight: FontWeight.w700),
                ),
              ),
              const Spacer(),
              Text(
                '${songs.length} songs · ${formatBytes(downloads.downloadedBytes)}',
                style: yomiText(
                  12.5,
                  weight: FontWeight.w600,
                  color: YomiColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < songs.length; i++)
          SongTile(
            key: ValueKey(songs[i].id),
            song: songs[i],
            onTap: () => player.playQueue(songs, startIndex: i),
          ),
      ],
    );
  }
}
