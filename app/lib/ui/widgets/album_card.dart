import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'playlist_cover.dart';

const double kCardWidth = 150;

class AlbumCard extends StatelessWidget {
  const AlbumCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.coverArtId,
    required this.onTap,
    this.onLongPress,
    this.cover,
  });

  factory AlbumCard.song(
    Song song,
    VoidCallback onTap, {
    VoidCallback? onLongPress,
  }) => AlbumCard(
    title: song.title,
    subtitle: song.artist,
    coverArtId: song.coverArtId,
    onTap: onTap,
    onLongPress: onLongPress,
  );

  factory AlbumCard.playlist(Playlist playlist, VoidCallback onTap) =>
      AlbumCard(
        title: playlist.name,
        subtitle: '${playlist.songCount} songs',
        coverArtId: playlist.coverArtId,
        onTap: onTap,
        cover: PlaylistCover(
          playlistId: playlist.id,
          coverArtId: playlist.coverArtId,
          size: kCardWidth,
          radius: kCardRadius,
          elevated: true,
          seed: playlist.name,
        ),
      );

  final String title;
  final String subtitle;
  final String? coverArtId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Shown instead of [coverArtId]'s picture, such as a mosaic for a mix.
  final Widget? cover;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      onLongPress: onLongPress,
      child: SizedBox(
        width: kCardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover ??
                CoverArt(
                  coverArtId: coverArtId,
                  size: kCardWidth,
                  radius: kCardRadius,
                  elevated: true,
                  seed: title,
                ),
            const SizedBox(height: 12),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(15, weight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(
                13,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPagePadding,
        YomiSpace.xl,
        kPagePadding,
        YomiSpace.m,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: yomiText(20, weight: FontWeight.w800, letterSpacing: -0.3),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A horizontally scrolling row of cards.
class CardRow extends StatelessWidget {
  const CardRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kCardWidth + 66,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (_, i) => children[i],
      ),
    );
  }
}
