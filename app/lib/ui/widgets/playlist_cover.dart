import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/playlist_covers_controller.dart';
import '../theme.dart';
import '../../core/models.dart';
import 'cover_art.dart';
import 'mosaic_cover.dart';

/// Lets the owner choose a picture for a playlist from their photos.
Future<void> pickPlaylistPicture(
  BuildContext context,
  String playlistId,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final covers = context.read<PlaylistCoversController>();
  try {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    final path = picked.isEmpty ? null : picked.first.path;
    if (path == null) return;
    await covers.setCover(playlistId, await File(path).readAsBytes());
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't use that picture: $error")),
    );
  }
}

/// A playlist's cover: the picture its owner chose, else four of its songs' covers
/// tiled together like Spotify does, else the usual album cover.
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({
    super.key,
    required this.playlistId,
    required this.coverArtId,
    required this.size,
    this.radius = 12,
    this.elevated = false,
    this.seed,
    this.onPick,
    this.songs,
  });

  /// The playlist's songs when known, for the tiled cover.
  final List<Song>? songs;

  final String playlistId;
  final String? coverArtId;
  final double size;
  final double radius;
  final bool elevated;
  final String? seed;

  /// Set where the owner can tap the cover to choose a picture.
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final cover = _cover(context);
    final pick = onPick;
    if (pick == null) return cover;
    final hasPicture = _hasPicture(context);
    return GestureDetector(
      onTap: pick,
      child: Stack(
        children: [
          cover,
          if (!hasPicture)
            Positioned(
              right: 10,
              bottom: 10,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.add_a_photo_rounded,
                  size: 20,
                  color: context.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _hasPicture(BuildContext context) {
    try {
      return context.watch<PlaylistCoversController>().hasCover(playlistId);
    } on ProviderNotFoundException {
      return false;
    }
  }

  Widget _cover(BuildContext context) {
    final known = songs;
    final fallback = known != null && MosaicCover.canTile(known)
        ? MosaicCover(
            songs: known,
            size: size,
            radius: radius,
            elevated: elevated,
            seed: seed,
          )
        : CoverArt(
            coverArtId: coverArtId,
            size: size,
            radius: radius,
            elevated: elevated,
            seed: seed,
          );
    String? url;
    try {
      url = context.watch<PlaylistCoversController>().urlFor(playlistId);
    } on ProviderNotFoundException {
      return fallback;
    }
    if (url == null) return fallback;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        key: ValueKey(url),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: pixels,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
