import 'package:flutter/material.dart';

import '../theme.dart';

const Duration _entranceDuration = Duration(milliseconds: 380);
const double _entranceTravel = 18;
const double _entranceStartScale = 0.9;

/// Slides, scales and fades a new message in from the side it belongs to.
/// Messages that were already there when the chat opened are shown as they are.
class MessageEntrance extends StatelessWidget {
  const MessageEntrance({
    super.key,
    required this.animate,
    required this.isMine,
    required this.child,
  });

  final bool animate;
  final bool isMine;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isReduced =
        MediaQuery.disableAnimationsOf(context) ||
        context.motion(YomiMotion.standard) == Duration.zero;
    if (!animate || isReduced) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: _entranceDuration,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, _entranceTravel * (1 - value)),
          child: Transform.scale(
            scale: _entranceStartScale + (1 - _entranceStartScale) * value,
            alignment: isMine ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        ),
      ),
    );
  }
}
