import 'package:flutter/material.dart';

import '../theme.dart';

const double kProfileBannerHeight = 112;
const double kProfileAvatarSize = 72;
const double _avatarRing = 3;
const int _bannerDecodeWidth = 1080;

/// A banner with the picture overlapping its lower edge. The banner fills its
/// area without stretching (the image is cropped to fit), fades into the page at
/// the bottom so the picture's ring sits on a calm edge, and falls back to the
/// accent colour when there is no image or it fails to load.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.avatar,
    this.banner,
    this.topInset = 0,
    this.bannerHeight = kProfileBannerHeight,
    this.avatarSize = kProfileAvatarSize,
    this.alignment = Alignment.centerLeft,
  });

  final Widget avatar;
  final ImageProvider? banner;
  final double topInset;
  final double bannerHeight;
  final double avatarSize;
  final Alignment alignment;

  /// Room the picture takes below the banner; content starts after it.
  double get overhang => avatarSize / 2 + YomiSpace.m;

  @override
  Widget build(BuildContext context) {
    final height = bannerHeight + topInset;
    final accent = context.accentDeep;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent, Color.lerp(accent, YomiColors.surface, 0.7)!],
        ),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: ClipRect(
            child: banner == null
                ? fallback
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      fallback,
                      Image(
                        image: ResizeImage(
                          banner!,
                          width: _bannerDecodeWidth,
                          policy: ResizeImagePolicy.fit,
                        ),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              YomiColors.surface.withValues(alpha: 0.55),
                            ],
                            stops: const [0.55, 1],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        Positioned(
          left: alignment == Alignment.centerLeft ? YomiSpace.l : 0,
          right: alignment == Alignment.center ? 0 : null,
          bottom: -avatarSize / 2,
          child: Align(
            alignment: alignment,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: YomiColors.surface,
                  width: _avatarRing,
                ),
              ),
              child: avatar,
            ),
          ),
        ),
      ],
    );
  }
}
