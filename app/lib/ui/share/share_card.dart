import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../theme.dart';
import '../widgets/cover_art.dart';

/// The three looks a shared song card can take, as on Spotify.
enum ShareCardStyle { cover, fade, black }

const double _cardWidth = 280;
const double _cardRadius = 26;
const Color _blackCard = Color(0xFF121212);
const Color _blackInner = Color(0xFF242424);

/// Below this saturation a colour counts as grey, and is kept grey.
const double _greyBelow = 0.08;

/// A colour bright enough to fill a card, made from a cover's (usually deep) colour.
/// Greys stay grey: boosting them would invent a hue (red, since grey's hue is 0).
Color brightCardColor(Color base) {
  final hsl = HSLColor.fromColor(base);
  final saturation = hsl.saturation < _greyBelow
      ? hsl.saturation
      : hsl.saturation.clamp(0.35, 0.8);
  return hsl.withLightness(0.62).withSaturation(saturation).toColor();
}

/// The darker panel inside the card, in the same hue.
Color innerCardColor(Color base) {
  final hsl = HSLColor.fromColor(base);
  return hsl.withLightness(0.2).withSaturation(hsl.saturation * 0.6).toColor();
}

/// The card's background for [style], given the cover's colour.
Gradient shareCardBackground(ShareCardStyle style, Color base) {
  final bright = brightCardColor(base);
  return switch (style) {
    ShareCardStyle.cover => LinearGradient(colors: [bright, bright]),
    ShareCardStyle.fade => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [bright, innerCardColor(base)],
    ),
    ShareCardStyle.black => const LinearGradient(
      colors: [_blackCard, _blackCard],
    ),
  };
}

/// The picture that gets shared: the cover, title and artist on a coloured card.
class ShareCard extends StatelessWidget {
  const ShareCard({
    super.key,
    required this.song,
    required this.style,
    required this.color,
  });

  final Song song;
  final ShareCardStyle style;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final inner = style == ShareCardStyle.black
        ? _blackInner
        : innerCardColor(color);
    const inset = 16.0;
    const coverSize = _cardWidth - inset * 4;
    return Container(
      width: _cardWidth,
      padding: const EdgeInsets.fromLTRB(inset, 36, inset, 36),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_cardRadius),
        gradient: shareCardBackground(style, color),
      ),
      child: Container(
        padding: const EdgeInsets.all(inset),
        decoration: BoxDecoration(
          color: inner,
          borderRadius: BorderRadius.circular(YomiRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            CoverArt(
              coverArtId: song.coverArtId,
              artist: song.artist,
              album: song.album,
              title: song.title,
              size: coverSize,
              radius: YomiRadius.art,
              seed: song.album,
            ),
            const SizedBox(height: 14),
            Text(
              song.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: yomiText(
                19,
                weight: FontWeight.w800,
                color: Colors.white,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(
                14,
                weight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(
                  Icons.graphic_eq_rounded,
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Text(
                  'Yomi',
                  style: yomiText(
                    14,
                    weight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
