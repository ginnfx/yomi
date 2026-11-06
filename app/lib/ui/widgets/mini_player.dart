import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/cover_palette.dart';
import '../../core/lyrics.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../pages/now_playing_page.dart';
import '../theme.dart';
import 'quick_song_actions.dart';
import 'cover_art.dart';
import 'nav_bar.dart';

const double kMiniPlayerHeight = 56;
const double kMiniPlayerGap = YomiSpace.xs;
const double _swipeVelocity = 250;

/// Room tab pages leave at the bottom so the mini player and nav bar never cover content.
const double kShellBottomClearance =
    kMiniPlayerHeight + kMiniPlayerGap + kNavBarHeight + YomiSpace.l;

/// Now-playing bar above the navigation. Tap or swipe up to expand, swipe sideways to skip.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final song = context.watch<PlayerController>().current;
    // Slides up from under the nav bar when something starts, and back down when it stops.
    return AnimatedSwitcher(
      duration: context.motion(YomiMotion.standard),
      switchInCurve: YomiMotion.curve,
      switchOutCurve: YomiMotion.curve,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.bottomCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: song == null
          ? const SizedBox(key: ValueKey('none'), width: double.infinity)
          : const _MiniPlayerBar(key: ValueKey('bar')),
    );
  }
}

class _MiniPlayerBar extends StatelessWidget {
  const _MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();
    final client = context.read<SessionController>().client;
    // Look the lyrics up now, so the player can open straight into them.
    final lyrics = Provider.of<LyricsService?>(context, listen: false);
    if (lyrics != null) unawaited(lyrics.forSong(client, song));
    return FutureBuilder<Color?>(
      future: context.read<CoverPalette>().colorFor(client, song.coverArtId),
      builder: (context, snapshot) => Padding(
        padding: const EdgeInsets.fromLTRB(
          YomiSpace.s,
          0,
          YomiSpace.s,
          kMiniPlayerGap,
        ),
        child: Builder(
          builder: (barContext) {
            void expand() => openNowPlaying(
              context,
              from: _rectOf(barContext),
              colour: _barColor(snapshot.data),
            );
            return GestureDetector(
              onTap: expand,
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) < -_swipeVelocity) expand();
              },
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
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: _barColor(snapshot.data)),
                duration: context.motion(YomiMotion.slow),
                curve: YomiMotion.curve,
                builder: (context, color, child) => Material(
                  clipBehavior: Clip.antiAlias,
                  borderRadius: BorderRadius.circular(YomiRadius.card),
                  color: color,
                  child: child,
                ),
                child: SizedBox(
                  height: kMiniPlayerHeight,
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          YomiSpace.s,
                          0,
                          YomiSpace.xs,
                          0,
                        ),
                        child: Row(
                          children: [
                            CoverArt(
                              coverArtId: song.coverArtId,
                              size: 40,
                              radius: YomiRadius.art,
                              heroTag: 'cover-${song.id}',
                              seed: song.album,
                            ),
                            const SizedBox(width: YomiSpace.m),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    song.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: yomiText(
                                      14,
                                      weight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    song.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: yomiText(
                                      12,
                                      weight: FontWeight.w500,
                                      color: YomiColors.faint(0.70),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!song.isFromYoutube)
                              LikeButton(song: song, size: 22),
                            if (MediaQuery.sizeOf(context).width >= 900)
                              IconButton(
                                tooltip: 'Previous song',
                                onPressed: player.previous,
                                icon: const Icon(Icons.skip_previous_rounded),
                              ),
                            IconButton(
                              tooltip: player.isPlaying ? 'Pause' : 'Play',
                              iconSize: 30,
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                player.togglePlay();
                              },
                              icon: Icon(
                                player.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
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
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _ProgressLine(
                          player: player,
                          total: song.duration,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
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
        return LinearProgressIndicator(
          value: fraction,
          minHeight: 2,
          backgroundColor: YomiColors.faint(0.12),
          color: YomiColors.textPrimary,
        );
      },
    );
  }
}

/// Where the bar sits on screen, so the player can grow out of it.
Rect? _rectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The bar's colour: the cover's own colour, toned to sit on the page.
Color _barColor(Color? cover) {
  if (cover == null) return YomiColors.surfaceHigh;
  return YomiColors.isLight
      ? Color.lerp(cover, YomiColors.surface, 0.72)!
      : Color.lerp(cover, Colors.black, 0.35)!;
}
