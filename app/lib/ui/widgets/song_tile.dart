import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/download_manager.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'download_badge.dart';
import 'equalizer.dart';
import 'playlist_sheet.dart';

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.extraActions = const [],
    this.leadingNumber,
  });

  final Song song;
  final VoidCallback onTap;
  final List<SongAction> extraActions;

  /// When set (album pages), shows the track number instead of the cover.
  final int? leadingNumber;

  @override
  Widget build(BuildContext context) {
    final isCurrent = context.select<PlayerController, bool>(
      (p) => p.current?.id == song.id,
    );
    final isPlaying = context.select<PlayerController, bool>(
      (p) => p.isPlaying,
    );
    final status = context.select<DownloadManager, DownloadStatus>(
      (d) => d.statusOf(song.id),
    );
    final progress = status == DownloadStatus.downloading
        ? context.select<DownloadManager, double>((d) => d.progressOf(song.id))
        : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: isCurrent
            ? context.accent.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Row(
              children: [
                if (leadingNumber != null)
                  SizedBox(
                    width: 40,
                    child: Center(
                      child: isCurrent
                          ? EqualizerBars(isPlaying: isPlaying)
                          : Text(
                              '$leadingNumber',
                              style: yomiText(
                                15,
                                weight: FontWeight.w600,
                                color: YomiColors.textSecondary,
                              ),
                            ),
                    ),
                  )
                else
                  CoverArt(
                    coverArtId: song.coverArtId,
                    size: 56,
                    radius: 12,
                    seed: song.album,
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: yomiText(
                          16,
                          weight: FontWeight.w700,
                          color: isCurrent
                              ? context.accent
                              : YomiColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (status != DownloadStatus.none) ...[
                            DownloadBadge(
                              status: status,
                              progress: progress,
                              size: 14,
                            ),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Text(
                              '${song.artist} · ${formatDuration(song.duration)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: yomiText(
                                13,
                                weight: FontWeight.w500,
                                color: YomiColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isCurrent && leadingNumber == null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: EqualizerBars(isPlaying: isPlaying),
                  ),
                IconButton(
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    color: YomiColors.textSecondary,
                  ),
                  onPressed: () =>
                      showSongMenu(context, song, extraActions: extraActions),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SongAction {
  const SongAction({
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

Future<void> showSongMenu(
  BuildContext context,
  Song song, {
  List<SongAction> extraActions = const [],
}) {
  final player = context.read<PlayerController>();
  final downloads = context.read<DownloadManager>();
  final session = context.read<SessionController>();
  final messenger = ScaffoldMessenger.of(context);
  void tell(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));
  final isSaved = downloads.statusOf(song.id) != DownloadStatus.none;

  final actions = <SongAction>[
    SongAction(
      icon: Icons.playlist_play_rounded,
      label: 'Play next',
      onSelected: () {
        player.playNext(song);
        tell('Playing next');
      },
    ),
    SongAction(
      icon: Icons.queue_music_rounded,
      label: 'Add to queue',
      onSelected: () {
        player.addToQueue(song);
        tell('Added to queue');
      },
    ),
    SongAction(
      icon: Icons.playlist_add_rounded,
      label: 'Add to playlist',
      onSelected: () => showAddToPlaylist(context, song),
    ),
    SongAction(
      icon: isSaved ? Icons.delete_outline_rounded : Icons.download_rounded,
      label: isSaved ? 'Remove download' : 'Download for offline',
      onSelected: () {
        if (isSaved) {
          downloads.remove(song);
          tell('Removed from this phone');
        } else {
          downloads.enqueue([song]);
          tell(downloads.pausedReason ?? 'Downloading…');
        }
      },
    ),
    SongAction(
      icon: song.isStarred
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      label: song.isStarred ? 'Remove from Liked' : 'Like',
      onSelected: () async {
        try {
          await (song.isStarred
              ? session.client.unstar(song.id)
              : session.client.star(song.id));
          tell(song.isStarred ? 'Removed from Liked' : 'Added to Liked');
        } on Exception catch (error) {
          tell('$error');
        }
      },
    ),
    ...extraActions,
  ];

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: CoverArt(
              coverArtId: song.coverArtId,
              size: 52,
              radius: 12,
            ),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(16, weight: FontWeight.w800),
            ),
            subtitle: Text(
              song.artist,
              style: yomiText(
                13,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          for (final action in actions)
            ListTile(
              leading: Icon(action.icon),
              title: Text(
                action.label,
                style: yomiText(15, weight: FontWeight.w600),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                action.onSelected();
              },
            ),
        ],
      ),
    ),
  );
}
