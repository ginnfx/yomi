import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/lyrics.dart';
import '../../core/models.dart';
import '../../state/download_manager.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../../state/settings.dart';
import '../theme.dart';
import '../widgets/cover_art.dart';
import '../widgets/download_badge.dart';
import '../widgets/equalizer.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/tinted_background.dart';

const double _maxCover = 460;
const double _compactCover = 56;
const double _dismissVelocity = 450;
const double _dismissDistanceShare = 0.25;

void openNowPlaying(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: YomiMotion.standard,
      pageBuilder: (_, _, _) => const NowPlayingPage(),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: YomiMotion.curve)).animate(animation),
        child: child,
      ),
    ),
  );
}

/// The player. Lyrics show by themselves whenever a song has them: beside the
/// art on wide screens, and under a small header on phones.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage>
    with SingleTickerProviderStateMixin {
  String? _lyricsSongId;
  Future<Lyrics?>? _lyrics;
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: YomiMotion.standard,
  );
  double _dragOffset = 0;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  Future<Lyrics?> _lyricsFor(Song song) {
    if (song.id != _lyricsSongId || _lyrics == null) {
      _lyricsSongId = song.id;
      _lyrics = context.read<LyricsService>().forSong(
        context.read<SessionController>().client,
        song,
      );
    }
    return _lyrics!;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _settle.stop();
    setState(() => _dragOffset = math.max(0, _dragOffset + details.delta.dy));
  }

  void _onDragEnd(DragEndDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    final shouldClose =
        (details.primaryVelocity ?? 0) > _dismissVelocity ||
        _dragOffset > height * _dismissDistanceShare;
    if (shouldClose) {
      Navigator.pop(context);
      return;
    }
    final start = _dragOffset;
    final tween = Tween<double>(
      begin: start,
      end: 0,
    ).chain(CurveTween(curve: YomiMotion.curve));
    void onTick() => setState(() => _dragOffset = tween.evaluate(_settle));
    _settle
      ..addListener(onTick)
      ..forward(from: 0).whenComplete(() => _settle.removeListener(onTick));
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final song = player.current;
    if (song == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      });
      return const Scaffold();
    }
    return Transform.translate(
      offset: Offset(0, _dragOffset),
      child: TintedBackground(
        coverArtId: song.coverArtId,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              child: FutureBuilder<Lyrics?>(
                future: _lyricsFor(song),
                builder: (context, snapshot) {
                  final lyrics = snapshot.data;
                  final hasLyrics = lyrics != null && lyrics.lines.isNotEmpty;
                  return context.isWideLayout
                      ? _WideLayout(
                          player: player,
                          song: song,
                          lyrics: hasLyrics ? lyrics : null,
                        )
                      : _PhoneLayout(
                          player: player,
                          song: song,
                          lyrics: hasLyrics ? lyrics : null,
                        );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Close player',
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
          onPressed: () => Navigator.pop(context),
        ),
        Expanded(
          child: Text(
            song.album,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: yomiText(13, weight: FontWeight.w700),
          ),
        ),
        IconButton(
          tooltip: 'Queue',
          icon: const Icon(Icons.queue_music_rounded),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => const _QueueSheet(),
          ),
        ),
      ],
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: YomiSpace.s),
    child: Text(
      message,
      style: yomiText(13, weight: FontWeight.w600, color: YomiColors.danger),
    ),
  );
}

/// Art as large as the space allows, without ever overflowing a short screen.
class _LargeArt extends StatelessWidget {
  const _LargeArt({required this.song, this.onTap});

  final Song song;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = math.min(_maxCover, math.min(box.maxWidth, box.maxHeight));
        return Center(
          child: GestureDetector(
            onTap: onTap,
            child: CoverArt(
              coverArtId: song.coverArtId,
              size: size,
              radius: YomiRadius.card,
              elevated: true,
              heroTag: 'cover-${song.id}',
              seed: song.album,
            ),
          ),
        );
      },
    );
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({required this.player, required this.song});

  final PlayerController player;
  final Song song;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SeekBar(player: player, fallbackTotal: song.duration),
        _Controls(player: player),
        const SizedBox(height: YomiSpace.l),
      ],
    );
  }
}

class _PhoneLayout extends StatelessWidget {
  const _PhoneLayout({
    required this.player,
    required this.song,
    required this.lyrics,
  });

  final PlayerController player;
  final Song song;
  final Lyrics? lyrics;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final lines = lyrics;
    final showLyrics = lines != null && !settings.prefersArtOverLyrics;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
      child: Column(
        children: [
          _TopBar(song: song),
          Expanded(
            child: AnimatedSwitcher(
              duration: YomiMotion.standard,
              child: showLyrics
                  ? _LyricsPane(
                      key: ValueKey('lyrics-${song.id}'),
                      song: song,
                      lyrics: lines,
                      onTapArt: () => settings.setPrefersArtOverLyrics(true),
                    )
                  : _ArtPane(
                      key: ValueKey('art-${song.id}'),
                      song: song,
                      onTapArt: lines == null
                          ? null
                          : () => settings.setPrefersArtOverLyrics(false),
                    ),
            ),
          ),
          if (player.error != null) _ErrorLine(message: player.error!),
          _PlayerControls(player: player, song: song),
        ],
      ),
    );
  }
}

class _ArtPane extends StatelessWidget {
  const _ArtPane({super.key, required this.song, required this.onTapArt});

  final Song song;
  final VoidCallback? onTapArt;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: YomiSpace.l),
            child: _LargeArt(song: song, onTap: onTapArt),
          ),
        ),
        _TitleRow(song: song),
        const SizedBox(height: YomiSpace.m),
      ],
    );
  }
}

class _LyricsPane extends StatelessWidget {
  const _LyricsPane({
    super.key,
    required this.song,
    required this.lyrics,
    required this.onTapArt,
  });

  final Song song;
  final Lyrics lyrics;
  final VoidCallback onTapArt;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Semantics(
              button: true,
              label: 'Show large artwork',
              child: GestureDetector(
                onTap: onTapArt,
                child: CoverArt(
                  coverArtId: song.coverArtId,
                  size: _compactCover,
                  radius: YomiRadius.art,
                  heroTag: 'cover-${song.id}',
                  seed: song.album,
                ),
              ),
            ),
            const SizedBox(width: YomiSpace.m),
            Expanded(child: _TitleRow(song: song, isCompact: true)),
          ],
        ),
        Expanded(child: LyricsView(lyrics: lyrics)),
      ],
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.player,
    required this.song,
    required this.lyrics,
  });

  final PlayerController player;
  final Song song;
  final Lyrics? lyrics;

  @override
  Widget build(BuildContext context) {
    final lines = lyrics;
    final artColumn = Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: YomiSpace.xl),
            child: _LargeArt(song: song),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxCover),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TitleRow(song: song),
              if (player.error != null) _ErrorLine(message: player.error!),
              const SizedBox(height: YomiSpace.m),
              _PlayerControls(player: player, song: song),
            ],
          ),
        ),
      ],
    );
    return Column(
      children: [
        _TopBar(song: song),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              YomiSpace.xxl,
              YomiSpace.s,
              YomiSpace.xxl,
              YomiSpace.s,
            ),
            child: lines == null
                ? Center(child: artColumn)
                : Row(
                    children: [
                      Expanded(child: artColumn),
                      const SizedBox(width: YomiSpace.xxl * 2),
                      Expanded(
                        child: LyricsView(
                          key: ValueKey(song.id),
                          lyrics: lines,
                          fontSize: 32,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.song, this.isCompact = false});

  final Song song;
  final bool isCompact;

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
                maxLines: isCompact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: yomiText(
                  isCompact ? 17 : 24,
                  weight: FontWeight.w800,
                  letterSpacing: -0.4,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: yomiText(
                  isCompact ? 13.5 : 16,
                  weight: FontWeight.w500,
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
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: YomiColors.textPrimary,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: YomiColors.textPrimary,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    trackShape: const RectangularSliderTrackShape(),
                  ),
                  child: SizedBox(
                    height: 24,
                    child: Slider(
                      value: value,
                      max: totalMs.toDouble(),
                      onChanged: (v) => setState(() => _dragValue = v),
                      onChangeEnd: (v) {
                        widget.player.seek(Duration(milliseconds: v.round()));
                        setState(() => _dragValue = null);
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.zero,
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
          iconSize: 38,
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
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: YomiColors.textPrimary,
              shape: BoxShape.circle,
            ),
            child: player.isBuffering
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.black,
                    ),
                  )
                : Icon(
                    player.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.black,
                    size: 38,
                  ),
          ),
        ),
        IconButton(
          iconSize: 38,
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
                      size: 44,
                      radius: YomiRadius.art,
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
