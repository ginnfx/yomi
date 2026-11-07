import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../state/playback_sync_controller.dart';
import '../../state/player_controller.dart';
import '../pages/now_playing_page.dart';
import '../theme.dart';
import 'cover_art.dart';

/// A stable desktop transport: song, playback, volume, and a seekable timeline.
class DesktopPlayer extends StatefulWidget {
  const DesktopPlayer({super.key});
  @override
  State<DesktopPlayer> createState() => _DesktopPlayerState();
}

class _DesktopPlayerState extends State<DesktopPlayer> {
  double? _dragPosition;
  double? _volume;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final sync = context.watch<PlaybackSyncController>();
    final song = player.current;
    final canPlay = song != null;
    final remote = sync.offer;
    return Material(
      color: YomiColors.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: YomiColors.hairline)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (song != null)
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => openNowPlaying(context),
                          child: CoverArt(
                            coverArtId: song.coverArtId,
                            size: 48,
                            radius: 8,
                            seed: song.album,
                            heroTag: 'cover-${song.id}',
                          ),
                        )
                      else
                        Icon(
                          Icons.music_note_rounded,
                          color: YomiColors.textSecondary,
                          size: 32,
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song?.title ?? 'Your next favorite is waiting',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: yomiText(13, weight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              remote != null
                                  ? 'From ${remote.deviceLabel} · ${song?.artist ?? ''}'
                                  : song?.artist ??
                                        'Choose a song to start listening',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: yomiText(
                                11,
                                color: YomiColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (canPlay && player.isCurrentCached)
                        Tooltip(
                          message: 'Available offline on this Mac',
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(
                              Icons.offline_pin_outlined,
                              size: 16,
                              color: YomiColors.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Shuffle',
                      iconSize: 19,
                      color: player.isShuffled
                          ? context.accent
                          : YomiColors.faint(0.54),
                      onPressed: canPlay ? player.toggleShuffle : null,
                      icon: const Icon(Icons.shuffle_rounded),
                    ),
                    IconButton(
                      tooltip: 'Previous song',
                      onPressed: canPlay ? player.previous : null,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    const SizedBox(width: 5),
                    IconButton.filled(
                      tooltip: remote != null
                          ? 'Continue on this Mac'
                          : player.isPlaying
                          ? 'Pause'
                          : 'Play',
                      style: IconButton.styleFrom(
                        backgroundColor: context.accent,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: !canPlay || sync.isTakingOver && remote != null
                          ? null
                          : () {
                              if (remote != null) {
                                sync.continueHere();
                              } else {
                                player.togglePlay();
                              }
                            },
                      icon: player.isBuffering
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Icon(
                              player.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                    ),
                    const SizedBox(width: 5),
                    IconButton(
                      tooltip: 'Next song',
                      onPressed: canPlay ? player.next : null,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    IconButton(
                      tooltip: 'Repeat',
                      iconSize: 19,
                      color: player.loopMode == LoopMode.off
                          ? YomiColors.faint(0.54)
                          : context.accent,
                      onPressed: canPlay ? player.cycleRepeat : null,
                      icon: Icon(
                        player.loopMode == LoopMode.one
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Now Playing, lyrics and queue',
                        onPressed: canPlay
                            ? () => openNowPlaying(context)
                            : null,
                        icon: const Icon(Icons.queue_music_rounded, size: 20),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.volume_up_outlined,
                        size: 18,
                        color: YomiColors.textSecondary,
                      ),
                      SizedBox(
                        width: 100,
                        child: Slider(
                          value: _volume ?? player.volume,
                          onChanged: (value) {
                            setState(() => _volume = value);
                            player.setVolume(value);
                          },
                          onChangeEnd: (_) => setState(() => _volume = null),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            StreamBuilder<Duration?>(
              stream: player.durationStream,
              builder: (context, duration) {
                final total = duration.data ?? song?.duration ?? Duration.zero;
                final totalMs = total.inMilliseconds
                    .clamp(1, 1 << 53)
                    .toDouble();
                return StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (context, position) {
                    final value =
                        (_dragPosition ??
                                position.data?.inMilliseconds.toDouble() ??
                                0)
                            .clamp(0.0, totalMs);
                    return SizedBox(
                      height: 26,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 42,
                            child: Text(
                              formatDuration(
                                Duration(milliseconds: value.round()),
                              ),
                              style: yomiText(
                                10,
                                color: YomiColors.textSecondary,
                              ),
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 4,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 10,
                                ),
                              ),
                              child: Slider(
                                value: value,
                                max: totalMs,
                                onChanged: canPlay
                                    ? (v) => setState(() => _dragPosition = v)
                                    : null,
                                onChangeEnd: (v) {
                                  player.seek(
                                    Duration(milliseconds: v.round()),
                                  );
                                  setState(() => _dragPosition = null);
                                },
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 42,
                            child: Text(
                              formatDuration(total),
                              textAlign: TextAlign.right,
                              style: yomiText(
                                10,
                                color: YomiColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
