import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/cover_palette.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../pages/now_playing_page.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'glass.dart';

const double kMiniPlayerHeight = 68;
const double kMiniPlayerGap = 8;
const double _swipeVelocity = 250;

/// Floating now-playing card. Tap to expand, swipe sideways to skip.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();
    final client = context.read<SessionController>().client;
    return FutureBuilder<Color?>(
      future: context.read<CoverPalette>().colorFor(client, song.coverArtId),
      builder: (context, snapshot) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, kMiniPlayerGap),
        child: GestureDetector(
          onTap: () => openNowPlaying(context),
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v < -_swipeVelocity) {
              HapticFeedback.lightImpact();
              player.next();
            } else if (v > _swipeVelocity) {
              HapticFeedback.lightImpact();
              player.previous();
            }
          },
          child: Glass(
            radius: 22,
            tint: snapshot.data == null
                ? null
                : Color.lerp(snapshot.data, Colors.black, 0.3),
            child: SizedBox(
              height: kMiniPlayerHeight,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
                    child: Row(
                      children: [
                        CoverArt(
                          coverArtId: song.coverArtId,
                          size: 48,
                          radius: 10,
                          heroTag: 'cover-${song.id}',
                          seed: song.album,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: yomiText(15, weight: FontWeight.w700),
                              ),
                              Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: yomiText(
                                  12.5,
                                  weight: FontWeight.w500,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (MediaQuery.sizeOf(context).width >= 900)
                          IconButton(
                            tooltip: 'Previous song',
                            onPressed: player.previous,
                            icon: const Icon(Icons.skip_previous_rounded),
                          ),
                        IconButton(
                          tooltip: player.isPlaying ? 'Pause' : 'Play',
                          iconSize: 34,
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            player.togglePlay();
                          },
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (child, anim) =>
                                ScaleTransition(scale: anim, child: child),
                            child: Icon(
                              player.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              key: ValueKey(player.isPlaying),
                            ),
                          ),
                        ),
                        if (MediaQuery.sizeOf(context).width >= 900)
                          IconButton(
                            tooltip: 'Next song',
                            onPressed: player.next,
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 4,
                    child: _ProgressLine(player: player, total: song.duration),
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

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.player, required this.total});

  final PlayerController player;
  final Duration total;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final fraction = total.inMilliseconds == 0
            ? 0.0
            : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        return ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 2.5,
            backgroundColor: Colors.white12,
            color: YomiColors.textPrimary,
          ),
        );
      },
    );
  }
}
