import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/spotify/imported_playlist.dart';
import '../../state/catalog_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/cover_art.dart';
import '../widgets/playlist_cover.dart';
import 'library_items.dart';

const double _rowCover = 64;
const double _coverRadius = 4;

/// A row of the library list, Spotify style: big cover, title, and "Playlist · ginnfx".
class LibraryRow extends StatelessWidget {
  const LibraryRow({super.key, required this.item, required this.onTap});

  final LibraryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kPagePadding,
          vertical: YomiSpace.s,
        ),
        child: Row(
          children: [
            LibraryCover(item: item, size: _rowCover),
            const SizedBox(width: YomiSpace.m + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: yomiText(16, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  LibrarySubtitle(item: item),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A square in the library's grid view: the cover with its name underneath.
class LibraryGridTile extends StatelessWidget {
  const LibraryGridTile({super.key, required this.item, required this.onTap});

  final LibraryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(YomiRadius.card),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: item is ArtistItem
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            LibraryCover(item: item, size: constraints.maxWidth),
            const SizedBox(height: YomiSpace.s),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(13, weight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            LibrarySubtitle(item: item, isCompact: true),
          ],
        ),
      ),
    );
  }
}

/// "📌 Playlist · ginnfx", with a green arrow for what's kept on this device.
class LibrarySubtitle extends StatelessWidget {
  const LibrarySubtitle({
    super.key,
    required this.item,
    this.isCompact = false,
  });

  final LibraryItem item;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final size = isCompact ? 12.0 : 13.5;
    final text = switch (item) {
      LikedSongsItem(:final owner) => 'Playlist · $owner',
      DownloadedSongsItem(:final count) =>
        count == 1 ? '1 song' : '$count songs',
      PlaylistItem(:final owner) => 'Playlist · $owner',
      ImportedItem() => 'Playlist · Spotify import',
      ArtistItem() => 'Artist',
    };
    final isKept = switch (item) {
      PlaylistItem(:final isKept) => isKept,
      DownloadedSongsItem() => true,
      _ => false,
    };
    return Row(
      mainAxisSize: isCompact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (item.isPinned && !isCompact) ...[
          Icon(Icons.push_pin_rounded, size: size + 2, color: context.accent),
          const SizedBox(width: 4),
        ],
        if (isKept && !isCompact) ...[
          Icon(
            Icons.arrow_circle_down_rounded,
            size: size + 2,
            color: context.accent,
          ),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: yomiText(
              size,
              weight: FontWeight.w500,
              color: YomiColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// The picture for a library row: a cover, a round artist photo, or a coloured tile.
class LibraryCover extends StatelessWidget {
  const LibraryCover({super.key, required this.item, required this.size});

  final LibraryItem item;
  final double size;

  @override
  Widget build(BuildContext context) => switch (item) {
    LikedSongsItem() => LikedSongsCover(size: size),
    DownloadedSongsItem() => _IconTile(
      size: size,
      icon: Icons.arrow_downward_rounded,
      colors: [context.accentDeep, context.accentDeep],
    ),
    PlaylistItem(:final playlist) => PlaylistCover(
      playlistId: playlist.id,
      coverArtId: playlist.coverArtId,
      songs: context.read<SessionController>().client.cachedPlaylistSongs(
        playlist.id,
      ),
      size: size,
      radius: _coverRadius,
      seed: playlist.name,
    ),
    ImportedItem(:final playlist) => PlaylistCover(
      playlistId: playlist.id,
      coverArtId: _firstCover(context, playlist),
      size: size,
      radius: _coverRadius,
      seed: playlist.name,
    ),
    ArtistItem(:final artist) => ArtistAvatar(
      artistId: artist.id,
      name: artist.name,
      size: size,
    ),
  };

  /// The first cover among an imported playlist's songs that are in the library.
  static String? _firstCover(BuildContext context, ImportedPlaylist playlist) {
    final byId = {
      for (final song in context.read<CatalogController>().songs) song.id: song,
    };
    for (final entry in playlist.entries) {
      final cover = byId[entry.songId]?.coverArtId;
      if (cover != null) return cover;
    }
    return null;
  }
}

/// Liked songs' cover: a heart on the accent gradient.
class LikedSongsCover extends StatelessWidget {
  const LikedSongsCover({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => _IconTile(
    size: size,
    icon: Icons.favorite_rounded,
    colors: [context.accentDeep, context.accentSecondary],
  );
}

class _IconTile extends StatelessWidget {
  const _IconTile({
    required this.size,
    required this.icon,
    required this.colors,
  });

  final double size;
  final IconData icon;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_coverRadius),
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.42),
    );
  }
}
