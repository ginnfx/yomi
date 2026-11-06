import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'cover_crop.dart';
import 'cover_sizes.dart';
import 'subsonic_client.dart';

const double _darken = 0.42;

/// Picks a deep colour from album art so screens can glow in the song's own colour.
class CoverPalette {
  final Map<String, Future<Color?>> _cache = {};
  final Map<String, Color> _ready = {};

  /// The colour if already known, so a screen can start in it with no flash.
  Color? peek(String? key) => key == null ? null : _ready[key];

  Future<Color?> colorFor(SubsonicClient client, String? coverArtId) {
    if (coverArtId == null) return Future.value();
    return colorForImage(
      coverArtId,
      () => CachedNetworkImageProvider(
        client.coverArtUri(coverArtId, size: smallCoverPx).toString(),
        cacheKey: coverCacheKey(coverArtId, smallCoverPx),
        cacheManager: coverCacheManager,
      ),
    );
  }

  /// The colour of any picture, such as a playlist's own photo, remembered by [key].
  Future<Color?> colorForImage(String key, ImageProvider Function() provider) =>
      _cache.putIfAbsent(key, () async {
        try {
          final scheme = await ColorScheme.fromImageProvider(
            provider: provider(),
            brightness: Brightness.dark,
          );
          final color = Color.lerp(
            scheme.primary,
            const Color(0xFF000000),
            _darken,
          );
          if (color != null) _ready[key] = color;
          return color;
        } on Object catch (error) {
          debugPrint('Could not read the colour of $key: $error');
          return null;
        }
      });
}
