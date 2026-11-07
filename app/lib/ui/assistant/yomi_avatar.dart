import 'package:flutter/material.dart';

import '../theme.dart';

const String _portraitAsset = 'assets/icon/icon.png';

/// Where the face sits in the portrait, and how much larger than the circle the
/// picture is drawn so the face fills it.
const double _faceX = 0.55;
const double _faceY = 0.3;
const double _zoom = 2.3;

/// Yomi's profile picture. A ring in the accent colour breathes gently while the
/// assistant is idle and pulses while it is thinking.
class YomiAvatar extends StatefulWidget {
  const YomiAvatar({super.key, this.size = 40, this.isThinking = false});

  final double size;
  final bool isThinking;

  @override
  State<YomiAvatar> createState() => _YomiAvatarState();
}

class _YomiAvatarState extends State<YomiAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(YomiAvatar old) {
    super.didUpdateWidget(old);
    if (old.isThinking != widget.isThinking) _syncAnimation();
  }

  void _syncAnimation() {
    final isReduced =
        MediaQuery.disableAnimationsOf(context) ||
        context.motion(YomiMotion.standard) == Duration.zero;
    if (isReduced || !widget.isThinking) {
      _pulse.animateTo(0, duration: const Duration(milliseconds: 200));
    } else {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final picture = size * _zoom;
    return Semantics(
      label: 'Yomi',
      image: true,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            final glow = _pulse.value;
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: YomiColors.surfaceHigh,
                border: Border.all(
                  color: context.accent.withValues(alpha: 0.35 + 0.5 * glow),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: context.accent.withValues(alpha: 0.35 * glow),
                    blurRadius: 4 + 14 * glow,
                    spreadRadius: 2 * glow,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: ClipOval(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: size / 2 - _faceX * picture - 2,
                  top: size / 2 - _faceY * picture - 2,
                  width: picture,
                  height: picture,
                  child: Image.asset(
                    _portraitAsset,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.auto_awesome_rounded,
                      size: size * 0.5,
                      color: context.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
