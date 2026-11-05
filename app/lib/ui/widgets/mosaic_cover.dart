import 'package:flutter/material.dart';

import '../../core/models.dart';
import 'cover_art.dart';

/// A cover made from four of the songs' own album covers, like a mix on Spotify. With
/// fewer than four different covers it shows the first one whole.
class MosaicCover extends StatelessWidget {
  const MosaicCover({
    super.key,
    required this.songs,
    required this.size,
    required this.radius,
    this.seed,
  });

  final List<Song> songs;
  final double size;
  final double radius;
  final String? seed;

  @override
  Widget build(BuildContext context) {
    final covers = <String>[];
    for (final song in songs) {
      final id = song.coverArtId;
      if (id != null && !covers.contains(id)) covers.add(id);
      if (covers.length == 4) break;
    }
    if (covers.length < 4) {
      return CoverArt(
        coverArtId: covers.firstOrNull,
        size: size,
        radius: radius,
        elevated: true,
        seed: seed,
      );
    }
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: Wrap(
          children: [
            for (final id in covers)
              CoverArt(coverArtId: id, size: half, radius: 0, seed: id),
          ],
        ),
      ),
    );
  }
}
