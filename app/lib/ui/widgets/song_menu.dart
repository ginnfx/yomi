import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/download_manager.dart';
import '../../state/home_controller.dart';
import '../../state/player_controller.dart';
import '../../state/reports_controller.dart';
import '../../state/session.dart';
import '../../state/settings.dart';
import '../pages/collection_page.dart';
import '../share/share_song_sheet.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'action_sheet.dart';
import 'playlist_sheet.dart';
import 'queue_sheet.dart';
import 'report_sheet.dart';

typedef SongAction = SheetAction;

/// What a song's ⋯ menu offers, in Spotify's order. Pure, so it can be tested.
///
/// [onRemoveFromPlaylist] is set when the song was opened from one of your playlists;
/// [isFromPlayer] adds the options that only make sense on the player.
List<SongAction> songMenuActions({
  required Song song,
  required bool isSaved,
  required bool hasQueue,
  required bool isFromPlayer,
  required bool showsLyrics,
  required VoidCallback onShare,
  required VoidCallback onToggleLyrics,
  required VoidCallback onAddToPlaylist,
  required VoidCallback onToggleLike,
  required VoidCallback onToggleDownload,
  required VoidCallback onPlayNext,
  required VoidCallback onAddToQueue,
  required VoidCallback onGoToQueue,
  required VoidCallback onGoToAlbum,
  required VoidCallback onShowLess,
  VoidCallback? onRemoveFromPlaylist,
  VoidCallback? onReport,
  List<SongAction> extraActions = const [],
}) {
  // A song playing from YouTube isn't in the library, so library actions can't work.
  final isInLibrary = !song.isFromYoutube;
  return [
    SongAction(
      icon: Icons.ios_share_rounded,
      label: 'Share',
      onSelected: onShare,
    ),
    if (isFromPlayer)
      SongAction(
        icon: Icons.subtitles_outlined,
        label: showsLyrics ? 'Lyrics · On' : 'Lyrics · Off',
        onSelected: onToggleLyrics,
      ),
    if (isInLibrary)
      SongAction(
        icon: song.isStarred
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        label: song.isStarred
            ? 'Remove from Liked songs'
            : 'Add to Liked songs',
        onSelected: onToggleLike,
      ),
    if (isInLibrary)
      SongAction(
        icon: Icons.add_circle_outline_rounded,
        label: 'Add to playlist',
        onSelected: onAddToPlaylist,
      ),
    if (isInLibrary && onRemoveFromPlaylist != null)
      SongAction(
        icon: Icons.remove_circle_outline_rounded,
        label: 'Remove from this playlist',
        onSelected: onRemoveFromPlaylist,
      ),
    if (isInLibrary)
      SongAction(
        icon: isSaved
            ? Icons.download_done_rounded
            : Icons.arrow_circle_down_outlined,
        label: isSaved ? 'Remove download' : 'Download',
        onSelected: onToggleDownload,
      ),
    SongAction(
      icon: Icons.playlist_play_rounded,
      label: 'Play next',
      onSelected: onPlayNext,
    ),
    SongAction(
      icon: Icons.playlist_add_rounded,
      label: 'Add to queue',
      onSelected: onAddToQueue,
    ),
    if (hasQueue)
      SongAction(
        icon: Icons.queue_music_rounded,
        label: 'Go to queue',
        onSelected: onGoToQueue,
      ),
    if (isInLibrary && song.albumId != null)
      SongAction(
        icon: Icons.album_outlined,
        label: 'Go to album',
        onSelected: onGoToAlbum,
      ),
    if (isInLibrary)
      SongAction(
        icon: Icons.highlight_off_rounded,
        label: 'Show less like this',
        onSelected: onShowLess,
      ),
    if (isInLibrary && onReport != null)
      SongAction(
        icon: Icons.flag_outlined,
        label: song.isClean ? 'Want the explicit version' : 'Report a problem…',
        onSelected: onReport,
      ),
    ...extraActions,
  ];
}

/// The ⋯ menu for a song: a frosted sheet in the colour of its cover.
Future<void> showSongMenu(
  BuildContext context,
  Song song, {
  List<SongAction> extraActions = const [],
  VoidCallback? onRemoveFromPlaylist,
  bool isFromPlayer = false,
}) {
  final player = context.read<PlayerController>();
  final downloads = context.read<DownloadManager>();
  final session = context.read<SessionController>();
  final settings = context.read<SettingsController>();
  final messenger = ScaffoldMessenger.of(context);
  void tell(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
  final isSaved = downloads.statusOf(song.id).isSavedOrSaving;

  final actions = songMenuActions(
    song: song,
    isSaved: isSaved,
    hasQueue: player.current != null,
    isFromPlayer: isFromPlayer,
    showsLyrics: !settings.prefersArtOverLyrics,
    onShare: () => showShareSong(context, song),
    // Absent in screens and tests built without a server connection.
    onReport: Provider.of<ReportsController?>(context, listen: false) == null
        ? null
        : () => showReportSheet(context, song),
    onToggleLyrics: () =>
        settings.setPrefersArtOverLyrics(!settings.prefersArtOverLyrics),
    onAddToPlaylist: () => showAddToPlaylist(context, song),
    onToggleLike: () async {
      try {
        await (song.isStarred
            ? session.client.unstar(song.id)
            : session.client.star(song.id));
        tell(
          song.isStarred ? 'Removed from Liked songs' : 'Added to Liked songs',
        );
      } on Exception catch (error) {
        debugPrint('Could not change Liked for ${song.id}: $error');
        tell("Couldn't change Liked songs");
      }
    },
    onToggleDownload: () {
      if (isSaved) {
        downloads.remove(song);
        tell('Removed from this device');
      } else {
        downloads.enqueue([song]);
        tell(downloads.pausedReason ?? 'Downloading…');
      }
    },
    onPlayNext: () {
      player.playNext(song);
      tell('Playing next');
    },
    onAddToQueue: () {
      player.addToQueue(song);
      tell('Added to queue');
    },
    onGoToQueue: () => showQueue(context),
    onGoToAlbum: () => openAlbum(
      context,
      id: song.albumId!,
      name: song.album,
      artist: song.artist,
      coverArtId: song.coverArtId,
    ),
    onShowLess: () async {
      await context.read<HomeController>().showLess(song, wholeArtist: false);
      tell("You'll see less like this");
    },
    onRemoveFromPlaylist: onRemoveFromPlaylist,
    extraActions: extraActions,
  );

  return showActionSheet(
    context,
    coverArtId: song.coverArtId,
    header: _Header(song: song),
    actions: actions,
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    return SheetHeader(
      cover: CoverArt(
        coverArtId: song.coverArtId,
        artist: song.artist,
        album: song.album,
        title: song.title,
        size: 52,
        radius: YomiRadius.art,
        seed: song.album,
      ),
      title: song.title,
      subtitle: '${song.artist} · ${song.album}',
    );
  }
}
