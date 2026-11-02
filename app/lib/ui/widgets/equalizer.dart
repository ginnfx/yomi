import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

const Duration _barPeriod = Duration(milliseconds: 900);
const List<double> _phases = [0.0, 0.35, 0.7];

/// Three dancing bars that mark the song that is playing. Frozen while paused.
class EqualizerBars extends StatefulWidget {
  const EqualizerBars({
    super.key,
    required this.isPlaying,
    this.size = 18,
    this.color,
  });

  final bool isPlaying;
  final double size;
  final Color? color;

  @override
  State<EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<EqualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _barPeriod,
  );

  @override
  void initState() {
    super.initState();
    if (widget.isPlaying) _controller.repeat();
  }

  @override
  void didUpdateWidget(EqualizerBars old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying && !_controller.isAnimating) _controller.repeat();
    if (!widget.isPlaying && _controller.isAnimating) _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final phase in _phases)
              Container(
                width: widget.size / 5,
                height:
                    widget.size *
                    (0.3 +
                        0.7 *
                            (0.5 +
                                0.5 *
                                    math.sin(
                                      2 * math.pi * (_controller.value + phase),
                                    ))),
                decoration: BoxDecoration(
                  color: widget.color ?? context.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
