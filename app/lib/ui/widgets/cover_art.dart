import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/cover_crop.dart';
import '../../core/artwork_lookup.dart';
import '../../core/cover_sizes.dart';
import '../../state/session.dart';
import '../theme.dart';

/// Cover art with a disk cache (so it also shows offline), a soft fade-in, and a
/// colourful fallback that is stable per song instead of a grey box.
class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.coverArtId,
    this.size = 56,
    this.radius = 12,
    this.elevated = false,
    this.heroTag,
    this.seed,
    this.artist,
    this.album,
    this.title,
  });

  final String? coverArtId;
  final double size;
  final double radius;
  final bool elevated;
  final Object? heroTag;

  /// Used to pick the fallback colours when there is no artwork.
  final String? seed;
  final String? artist, album, title;

  @override
  Widget build(BuildContext context) {
    final fallback = _Fallback(size: size, seedText: seed ?? coverArtId ?? '');
    Widget image = fallback;
    if (coverArtId != null || artist != null) {
      final client = context.read<SessionController>().client;
      final pixels = coverPixelsFor(size);
      final service = CoverImageService.instance;
      final key = coverCacheKey(
        coverArtId ?? 'missing-${artist ?? ''}-${album ?? ''}',
        pixels,
      );
      // While the big version loads, show the small one we already have instead of a blank.
      final placeholder =
          service.peek(key) ??
          service.peek(coverCacheKey(coverArtId ?? '', smallCoverPx));
      image = _TrimmedImage(
        future: () async {
          if (coverArtId != null) {
            final image = await service.load(
              client.coverArtUri(coverArtId, size: pixels).toString(),
              key,
            );
            if (image != null) return image;
          }
          if (artist == null) return null;
          final url = await ArtworkLookup.instance.find(
            artist!,
            album ?? '',
            title ?? '',
          );
          return url == null
              ? null
              : service.load(url, 'external-$url-$pixels');
        }(),
        initial: placeholder,
        fallback: fallback,
      );
    }
    Widget result = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: elevated
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: image,
        ),
      ),
    );
    if (heroTag != null) result = Hero(tag: heroTag!, child: result);
    return result;
  }
}

/// Shows a cover trimmed to its real artwork, fading in once ready.
class _TrimmedImage extends StatelessWidget {
  const _TrimmedImage({
    required this.future,
    required this.fallback,
    this.initial,
  });

  final Future<ui.Image?> future;
  final ui.Image? initial;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image?>(
      future: future,
      initialData: initial,
      builder: (context, snapshot) {
        final image = snapshot.data;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: image == null
              ? KeyedSubtree(key: const ValueKey('fallback'), child: fallback)
              : RawImage(
                  key: ValueKey(image),
                  image: image,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                ),
        );
      },
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.size, required this.seedText});

  final double size;
  final String seedText;

  @override
  Widget build(BuildContext context) {
    final hue = (seedText.hashCode.abs() % 360).toDouble();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.45, 0.28).toColor(),
            HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.16).toColor(),
          ],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: Colors.white.withValues(alpha: 0.35),
        size: size * 0.38,
      ),
    );
  }
}

/// Round artist picture: the first album's cover, or a coloured monogram when there is none.
class ArtistAvatar extends StatelessWidget {
  const ArtistAvatar({
    super.key,
    required this.artistId,
    required this.name,
    this.size = 56,
  });

  final String artistId;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final client = context.read<SessionController>().client;
    return FutureBuilder<String?>(
      future: client.artistCoverId(artistId),
      builder: (context, snapshot) {
        final coverId = snapshot.data;
        return ClipOval(
          child: coverId != null
              ? CoverArt(coverArtId: coverId, size: size, radius: size / 2)
              : _Monogram(name: name, size: size),
        );
      },
    );
  }
}

class _Monogram extends StatelessWidget {
  const _Monogram({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hue = (name.hashCode.abs() % 360).toDouble();
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.55, 0.42).toColor(),
            HSLColor.fromAHSL(1, (hue + 50) % 360, 0.6, 0.28).toColor(),
          ],
        ),
      ),
      child: Text(
        initial,
        style: yomiText(size * 0.42, weight: FontWeight.w800),
      ),
    );
  }
}
