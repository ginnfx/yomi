import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/download_manager.dart';
import '../../state/player_controller.dart';
import '../theme.dart';
import '../widgets/cover_art.dart';
import '../widgets/download_badge.dart';
import '../widgets/equalizer.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/tinted_background.dart';

const double _maxCover = 360;

void openNowPlaying(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => const NowPlayingPage(),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
        child: child,
      ),
    ),
  );
}

class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  static const double _dismissVelocity = 450;
  bool _showLyrics = false;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final song = player.current;
    if (song == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.canPop(context))
          Navigator.pop(context);
      });
      return const Scaffold();
    }
    final width = MediaQuery.sizeOf(context).width;
    final coverSize = (width - kPagePadding * 2).clamp(0.0, _maxCover);
    return TintedBackground(
      coverArtId: song.coverArtId,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(
              opacity: 0.55,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 46, sigmaY: 46),
                child: Transform.scale(
                  scale: 1.7,
                  child: CoverArt(
                    coverArtId: song.coverArtId,
                    size: width,
                    radius: 0,
                    seed: song.album,
                  ),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.2),
                    YomiColors.background.withValues(alpha: 0.92),
                  ],
                ),
              ),
            ),
            SafeArea(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) > _dismissVelocity)
                    Navigator.pop(context);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 34,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Lyrics',
                            icon: Icon(
                              Icons.lyrics_rounded,
                              color: _showLyrics ? context.accent : null,
                            ),
                            onPressed: () =>
                                setState(() => _showLyrics = !_showLyrics),
                          ),
                          IconButton(
                            icon: const Icon(Icons.queue_music_rounded),
                            onPressed: () => _showQueue(context),
                          ),
                        ],
                      ),
                      if (_showLyrics)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: LyricsView(
                              key: ValueKey(song.id),
                              song: song,
                            ),
                          ),
                        )
                      else ...[
                        const Spacer(flex: 2),
                        AnimatedScale(
                          scale: player.isPlaying ? 1.0 : 0.88,
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeOutBack,
                          child: CoverArt(
                            coverArtId: song.coverArtId,
                            size: coverSize,
                            radius: 26,
                            elevated: true,
                            heroTag: 'cover-${song.id}',
                            seed: song.album,
                          ),
                        ),
                        const SizedBox(height: 30),
                      ],
                      _TitleRow(song: song),
                      if (player.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            player.error!,
                            style: yomiText(
                              13,
                              weight: FontWeight.w600,
                              color: Colors.redAccent,
                            ),
                          ),
                        ),
                      const SizedBox(height: 14),
                      _SeekBar(player: player, fallbackTotal: song.duration),
                      const SizedBox(height: 6),
                      _Controls(player: player),
                      const SizedBox(height: 22),
                      if (!_showLyrics) const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _QueueSheet(),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadManager>();
    final status = downloads.statusOf(song.id);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: yomiText(
                  26,
                  weight: FontWeight.w800,
                  letterSpacing: -0.5,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: yomiText(
                  16.5,
                  weight: FontWeight.w600,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: status == DownloadStatus.done
              ? 'Remove download'
              : 'Download',
          onPressed: () {
            HapticFeedback.selectionClick();
            if (status == DownloadStatus.done ||
                status == DownloadStatus.queued ||
                status == DownloadStatus.downloading) {
              downloads.remove(song);
            } else {
              downloads.enqueue([song]);
            }
          },
          icon: status == DownloadStatus.none || status == DownloadStatus.failed
              ? const Icon(Icons.download_rounded, size: 28)
              : DownloadBadge(
                  status: status,
                  progress: downloads.progressOf(song.id),
                  size: 26,
                ),
        ),
      ],
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player, required this.fallbackTotal});

  final PlayerController player;
  final Duration fallbackTotal;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: widget.player.durationStream,
      builder: (context, durationSnap) {
        final total = durationSnap.data ?? widget.fallbackTotal;
        final totalMs = total.inMilliseconds <= 0 ? 1 : total.inMilliseconds;
        return StreamBuilder<Duration>(
          stream: widget.player.positionStream,
          builder: (context, positionSnap) {
            final position = positionSnap.data ?? Duration.zero;
            final value =
                _dragValue ??
                position.inMilliseconds.clamp(0, totalMs).toDouble();
            return Column(
              children: [
                Slider(
                  value: value,
                  max: totalMs.toDouble(),
                  onChanged: (v) => setState(() => _dragValue = v),
                  onChangeEnd: (v) {
                    widget.player.seek(Duration(milliseconds: v.round()));
                    setState(() => _dragValue = null);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatDuration(Duration(milliseconds: value.round())),
                        style: yomiText(
                          12,
                          weight: FontWeight.w600,
                          color: Colors.white60,
                        ),
                      ),
                      Text(
                        formatDuration(total),
                        style: yomiText(
                          12,
                          weight: FontWeight.w600,
                          color: Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final repeatIcon = player.loopMode == LoopMode.one
        ? Icons.repeat_one_rounded
        : Icons.repeat_rounded;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: Icon(
            Icons.shuffle_rounded,
            color: player.isShuffled ? context.accent : Colors.white54,
          ),
          onPressed: () {
            HapticFeedback.selectionClick();
            player.toggleShuffle();
          },
        ),
        IconButton(
          iconSize: 44,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: () {
            HapticFeedback.lightImpact();
            player.previous();
          },
        ),
        GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            player.togglePlay();
          },
          child: Container(
            width: 78,
            height: 78,
            decoration: const BoxDecoration(
              color: YomiColors.textPrimary,
              shape: BoxShape.circle,
            ),
            child: player.isBuffering
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.black,
                    ),
                  )
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: Icon(
                      player.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      key: ValueKey(player.isPlaying),
                      color: Colors.black,
                      size: 46,
                    ),
                  ),
          ),
        ),
        IconButton(
          iconSize: 44,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: () {
            HapticFeedback.lightImpact();
            player.next();
          },
        ),
        IconButton(
          icon: Icon(
            repeatIcon,
            color: player.loopMode == LoopMode.off
                ? Colors.white54
                : context.accent,
          ),
          onPressed: () {
            HapticFeedback.selectionClick();
            player.cycleRepeat();
          },
        ),
      ],
    );
  }
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                4,
                kPagePadding,
                12,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Queue',
                  style: yomiText(22, weight: FontWeight.w800),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: player.queue.length,
                itemBuilder: (context, i) {
                  final song = player.queue[i];
                  final isCurrent = i == player.index;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: kPagePadding,
                    ),
                    leading: CoverArt(
                      coverArtId: song.coverArtId,
                      size: 48,
                      radius: 10,
                      seed: song.album,
                    ),
                    title: Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: yomiText(
                        15,
                        weight: FontWeight.w700,
                        color: isCurrent
                            ? context.accent
                            : YomiColors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: yomiText(
                        12.5,
                        weight: FontWeight.w500,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                    trailing: isCurrent
                        ? EqualizerBars(isPlaying: player.isPlaying)
                        : null,
                    onTap: () {
                      player.jumpTo(i);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
