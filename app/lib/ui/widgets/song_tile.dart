import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/download_manager.dart';
import '../../state/player_controller.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'download_badge.dart';
import 'equalizer.dart';
import 'song_menu.dart';

export 'song_menu.dart' show SongAction, showSongMenu;

const double _unavailableOpacity = 0.4;

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.extraActions = const [],
    this.leadingNumber,
    this.onRemoveFromPlaylist,
  });

  /// Set when listed in one of your playlists; adds "Remove from this playlist".
  final VoidCallback? onRemoveFromPlaylist;

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
    final isAvailable = context.select<PlayerController, bool>(
      (p) => p.isAvailableNow(song),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Opacity(
        opacity: isAvailable ? 1 : _unavailableOpacity,
        child: Material(
          color: isCurrent
              ? context.accent.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              if (!isAvailable) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text("This song isn't saved on this device"),
                    ),
                  );
                return;
              }
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
                      artist: song.artist,
                      album: song.album,
                      title: song.title,
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
                            if (song.isClean) ...[
                              const _CleanTag(),
                              const SizedBox(width: 5),
                            ],
                            Flexible(
                              child: Text(
                                song.artist,
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
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      color: YomiColors.textSecondary,
                    ),
                    tooltip: 'More options',
                    onPressed: () => showSongMenu(
                      context,
                      song,
                      extraActions: extraActions,
                      onRemoveFromPlaylist: onRemoveFromPlaylist,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Marks a censored copy, so it's clear why someone might ask for the explicit one.
class _CleanTag extends StatelessWidget {
  const _CleanTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: YomiColors.textSecondary),
    ),
    child: Text(
      'CLEAN',
      style: yomiText(
        9,
        weight: FontWeight.w800,
        color: YomiColors.textSecondary,
      ),
    ),
  );
}
