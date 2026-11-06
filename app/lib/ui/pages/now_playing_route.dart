import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Marks the layer in the mini bar's colour that covers the player as it opens.
const Key kMiniBarColourKey = ValueKey('mini-bar-colour');

/// The bar's colour holds as it starts to grow, then dissolves into the player by
/// half way, while it's still growing.
const Interval _colourFade = Interval(0, 0.5, curve: Curves.easeIn);

/// The curve heroes fly on, so the cover and the growing player move together.
const Curve _growCurve = Curves.fastOutSlowIn;

/// The page rises this much as it grows, so it settles into place instead of
/// appearing all at once.
const double _rise = 48;

/// The player's visible area at [t]: the mini bar at 0, the whole screen at 1.
Rect playerRectAt(Rect origin, Size screen, double t) =>
    Rect.lerp(origin, Offset.zero & screen, t)!;

/// How much of the opening a downward drag of [dy] undoes. The top edge travels from
/// the top of the screen to the bar's top, so the edge stays under the finger.
double dragFraction({
  required double dy,
  required Rect origin,
  required Size screen,
}) {
  final distance = origin.top > 0 ? origin.top : screen.height;
  return dy / distance;
}

/// Opens the player by growing it out of the mini bar, the way the bar itself would
/// expand: its colour fades into the player's, the cover flies to its place, and the
/// page rises the last few points. Closing runs it backwards, and a drag down runs it
/// under the finger. With no [origin] (opened from somewhere else) it slides up.
class NowPlayingRoute extends PageRoute<void> {
  NowPlayingRoute({
    required this.builder,
    required this.openDuration,
    required this.closeDuration,
    this.origin,
    this.originColor,
  }) : super(fullscreenDialog: true);

  final WidgetBuilder builder;
  final Rect? origin;
  final Color? originColor;
  final Duration openDuration;
  final Duration closeDuration;

  @override
  Duration get transitionDuration => openDuration;

  @override
  Duration get reverseTransitionDuration => closeDuration;

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  /// Whether a drag down should shrink the player back into the bar.
  bool get canDragToClose => origin != null && isCurrent;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Under a finger the player follows it exactly; on its own it eases.
    final isDragging = navigator?.userGestureInProgress ?? false;
    final progress = isDragging
        ? animation
        : CurvedAnimation(
            parent: animation,
            curve: _growCurve,
            reverseCurve: _growCurve.flipped,
          );
    final from = origin;
    if (from == null) {
      return SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(progress),
        child: child,
      );
    }
    return _GrowFromBar(
      progress: progress,
      origin: from,
      colour: originColor ?? YomiColors.surfaceHigh,
      child: child,
    );
  }

  /// Moves the player toward closed by [fraction] of the way, following a drag.
  void dragBy(double fraction) {
    final nav = navigator;
    final animation = controller;
    if (nav == null || animation == null) return;
    if (!nav.userGestureInProgress) nav.didStartUserGesture();
    animation.value = (animation.value - fraction).clamp(0.0, 1.0);
  }

  /// Ends a drag: closes into the bar, or springs back open.
  void endDrag({required bool close}) {
    final nav = navigator;
    final animation = controller;
    if (nav == null || animation == null) return;
    if (close) {
      nav.pop();
    } else {
      animation.forward();
    }
    if (!nav.userGestureInProgress) return;
    if (!animation.isAnimating) {
      nav.didStopUserGesture();
      return;
    }
    // Heroes keep flying under the gesture until the player has settled.
    late final AnimationStatusListener onSettled;
    onSettled = (status) {
      if (status.isAnimating) return;
      animation.removeStatusListener(onSettled);
      if (nav.userGestureInProgress) nav.didStopUserGesture();
    };
    animation.addStatusListener(onSettled);
  }
}

class _GrowFromBar extends StatelessWidget {
  const _GrowFromBar({
    required this.progress,
    required this.origin,
    required this.colour,
    required this.child,
  });

  final Animation<double> progress;
  final Rect origin;
  final Color colour;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, page) {
        final t = progress.value;
        if (t >= 1) return page!;
        final rect = playerRectAt(origin, screen, t);
        final radius = lerpDouble(YomiRadius.card, 0, t)!;
        final colourOpacity = 1 - _colourFade.transform(t);
        return ClipRRect(
          clipper: _RectClipper(
            RRect.fromRectAndRadius(rect, Radius.circular(radius)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform.translate(
                offset: Offset(0, (1 - t) * _rise),
                child: page,
              ),
              if (colourOpacity > 0)
                IgnorePointer(
                  child: Opacity(
                    opacity: colourOpacity,
                    child: ColoredBox(key: kMiniBarColourKey, color: colour),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RectClipper extends CustomClipper<RRect> {
  const _RectClipper(this.shape);

  final RRect shape;

  @override
  RRect getClip(Size size) => shape;

  @override
  bool shouldReclip(_RectClipper oldClipper) => oldClipper.shape != shape;
}
