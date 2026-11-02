import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'cover_sizes.dart';
import 'subsonic_client.dart';

const double _darken = 0.42;

/// Picks a deep colour from album art so screens can glow in the song's own colour.
class CoverPalette {
  final Map<String, Future<Color?>> _cache = {};
  final Map<String, Color> _ready = {};

  /// The colour if already known, so a screen can start in it with no flash.
  Color? peek(String? coverArtId) =>
      coverArtId == null ? null : _ready[coverArtId];

  Future<Color?> colorFor(SubsonicClient client, String? coverArtId) {
    if (coverArtId == null) return Future.value();
    return _cache.putIfAbsent(coverArtId, () async {
      try {
        final provider = CachedNetworkImageProvider(
          client.coverArtUri(coverArtId, size: smallCoverPx).toString(),
          cacheKey: coverCacheKey(coverArtId, smallCoverPx),
        );
        final scheme = await ColorScheme.fromImageProvider(
          provider: provider,
          brightness: Brightness.dark,
        );
        final color = Color.lerp(
          scheme.primary,
          const Color(0xFF000000),
          _darken,
        );
        if (color != null) _ready[coverArtId] = color;
        return color;
      } on Object {
        return null;
      }
    });
  }
}
