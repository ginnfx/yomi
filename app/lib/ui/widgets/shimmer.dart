import 'package:flutter/material.dart';

import '../theme.dart';

const Duration _shimmerPeriod = Duration(milliseconds: 1400);

/// A softly sweeping highlight used for loading placeholders instead of a spinner.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _shimmerPeriod,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) {
          final t = _controller.value;
          return LinearGradient(
            begin: Alignment(-1.5 + 3 * t, -0.3),
            end: Alignment(-0.5 + 3 * t, 0.3),
            colors: const [
              YomiColors.surfaceHigh,
              Color(0xFF2E2E3E),
              YomiColors.surfaceHigh,
            ],
            stops: const [0.25, 0.5, 0.75],
          ).createShader(rect);
        },
        child: child,
      ),
    );
  }
}

/// A grey rounded block to shimmer.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height = 16, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: YomiColors.surfaceHigh,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/// Placeholder rows shaped like song tiles.
class SongListSkeleton extends StatelessWidget {
  const SongListSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Column(
        children: [
          for (var i = 0; i < rows; i++)
            const Padding(
              padding: EdgeInsets.symmetric(
                horizontal: kPagePadding,
                vertical: 8,
              ),
              child: Row(
                children: [
                  SkeletonBox(width: 56, height: 56, radius: 12),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 180, height: 14),
                        SizedBox(height: 8),
                        SkeletonBox(width: 110, height: 12),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Placeholder for a row of album cards.
class CardRowSkeleton extends StatelessWidget {
  const CardRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: SizedBox(
        height: 214,
        child: Padding(
          padding: EdgeInsets.only(left: kPagePadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CardPlaceholder(),
              SizedBox(width: 14),
              _CardPlaceholder(),
              SizedBox(width: 14),
              _CardPlaceholder(),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardPlaceholder extends StatelessWidget {
  const _CardPlaceholder();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SkeletonBox(width: 150, height: 150, radius: kCardRadius),
      SizedBox(height: 10),
      SkeletonBox(width: 110, height: 13),
      SizedBox(height: 6),
      SkeletonBox(width: 70, height: 11),
    ],
  );
}
