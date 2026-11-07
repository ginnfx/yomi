import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

const double _maxCover = 270;
const double _coverShare = 0.66;

/// How much of the cover's colour washes the top of the page.
const double headerTintStrength = 0.85;

/// The size the big cover takes on a screen [width] wide.
double headerCoverSize(double width) =>
    math.min(width * _coverShare, _maxCover);

/// The top of a playlist or album page, as on Spotify: the cover's colour fading into
/// the page behind a big cover, the title, who made it, and the play controls.
class CollectionHeader extends StatelessWidget {
  const CollectionHeader({
    super.key,
    required this.color,
    required this.cover,
    required this.title,
    required this.byline,
    required this.meta,
    required this.actions,
  });

  final Color color;
  final Widget cover;
  final String title;

  /// Who made it, usually with a small avatar; null to leave the line out.
  final Widget? byline;

  /// "Playlist · 34 songs, 2 h 10 min".
  final Widget meta;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final page = context.pageColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, Color.lerp(page, color, 0.35)!, page],
          stops: const [0, 0.6, 1],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: YomiSpace.s),
          Center(child: cover),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              YomiSpace.xl,
              kPagePadding,
              YomiSpace.s,
            ),
            child: Text(
              title,
              style: yomiText(
                26,
                weight: FontWeight.w800,
                letterSpacing: -0.6,
                height: 1.12,
              ),
            ),
          ),
          if (byline case final byline?)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                2,
                kPagePadding,
                YomiSpace.s,
              ),
              child: byline,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            child: meta,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              YomiSpace.s,
              YomiSpace.s,
              kPagePadding,
              YomiSpace.s,
            ),
            child: actions,
          ),
        ],
      ),
    );
  }
}

/// The big round play button on the right, which pauses when this list is playing.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.isPlaying, required this.onTap});

  final bool isPlaying;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: isPlaying ? 'Pause' : 'Play',
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onTap!();
              },
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: context.accent,
          ),
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: context.onAccent,
            size: 34,
          ),
        ),
      ),
    );
  }
}

/// A plain outlined icon in the action row, like Spotify's download and ⋯ buttons.
class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.progress,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;

  /// Shown as a ring while something is downloading: null for none, or 0–1.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final ring = progress;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Stack(
        alignment: Alignment.center,
        children: [
          if (ring != null)
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                value: ring > 0 && ring < 1 ? ring : null,
                strokeWidth: 2.2,
                color: context.accent,
              ),
            ),
          Icon(icon, size: 28, color: color ?? YomiColors.faint(0.75)),
        ],
      ),
    );
  }
}
