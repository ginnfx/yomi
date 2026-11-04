import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/download_manager.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/cover_art.dart';
import '../widgets/error_view.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/shimmer.dart';
import '../widgets/song_tile.dart';
import '../widgets/tinted_background.dart';

const double _heroCover = 230;

/// An album, a playlist, or Liked songs: coloured header, play controls, and the tracks.
class CollectionPage extends StatefulWidget {
  const CollectionPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.loadSongs,
    this.coverArtId,
    this.playlist,
  });

  final String title;
  final String subtitle;
  final String? coverArtId;
  final Future<List<Song>> Function() loadSongs;

  /// Set for editable playlists: enables swipe-to-remove, rename and delete.
  final Playlist? playlist;

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  late Future<List<Song>> _songs = widget.loadSongs();
  late String _title = widget.title;

  void _reload() => setState(() => _songs = widget.loadSongs());

  Future<void> _rename() async {
    final client = context.read<SessionController>().client;
    final name = await promptForName(
      context,
      title: 'Rename playlist',
      initial: _title,
    );
    if (name == null || name.isEmpty) return;
    await client.renamePlaylist(widget.playlist!.id, name);
    if (mounted) setState(() => _title = name);
  }

  Future<void> _delete() async {
    final client = context.read<SessionController>().client;
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Delete "$_title"?',
          style: yomiText(18, weight: FontWeight.w800),
        ),
        content: Text(
          'The songs stay in the library.',
          style: yomiText(
            14,
            weight: FontWeight.w500,
            color: YomiColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await client.deletePlaylist(widget.playlist!.id);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final downloads = context.watch<DownloadManager>();
    final client = context.read<SessionController>().client;
    return TintedBackground(
      coverArtId: widget.coverArtId,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        bottomNavigationBar: const SafeArea(child: MiniPlayer()),
        appBar: AppBar(
          actions: [
            if (widget.playlist != null)
              PopupMenuButton<String>(
                onSelected: (value) =>
                    value == 'rename' ? _rename() : _delete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete playlist'),
                  ),
                ],
              ),
          ],
        ),
        body: FutureBuilder<List<Song>>(
          future: _songs,
          builder: (context, snapshot) {
            final songs = snapshot.data ?? const <Song>[];
            final savedCount = downloads.downloadedCountOf(songs);
            final isFullySaved = songs.isNotEmpty && savedCount == songs.length;
            final isBusy = songs.any((s) {
              final status = downloads.statusOf(s.id);
              return status == DownloadStatus.queued ||
                  status == DownloadStatus.downloading;
            });
            return ListView(
              children: [
                Center(
                  child: CoverArt(
                    coverArtId:
                        widget.coverArtId ??
                        (songs.isEmpty ? null : songs.first.coverArtId),
                    size: _heroCover,
                    radius: 20,
                    elevated: true,
                    seed: _title,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kPagePadding,
                    24,
                    kPagePadding,
                    4,
                  ),
                  child: Text(
                    _title,
                    style: yomiText(
                      28,
                      weight: FontWeight.w800,
                      letterSpacing: -0.6,
                      height: 1.1,
                    ),
                  ),
                ),
                if (widget.subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: kPagePadding,
                    ),
                    child: Text(
                      widget.subtitle,
                      style: yomiText(
                        14,
                        weight: FontWeight.w600,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kPagePadding,
                    18,
                    kPagePadding,
                    12,
                  ),
                  child: Row(
                    children: [
                      _RoundAction(
                        icon: isFullySaved
                            ? Icons.arrow_circle_down_rounded
                            : Icons.download_rounded,
                        color: isFullySaved
                            ? YomiColors.success
                            : YomiColors.textPrimary,
                        isBusy: isBusy,
                        progress: songs.isEmpty ? 0 : savedCount / songs.length,
                        tooltip: isFullySaved ? 'Downloaded' : 'Download',
                        onTap: songs.isEmpty
                            ? null
                            : () async {
                                HapticFeedback.selectionClick();
                                final messenger = ScaffoldMessenger.of(context);
                                if (isFullySaved) {
                                  for (final song in songs) {
                                    await downloads.remove(song);
                                  }
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text('Removed from this phone'),
                                    ),
                                  );
                                } else {
                                  downloads.enqueue(songs);
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        downloads.pausedReason ??
                                            'Downloading ${songs.length - savedCount} songs…',
                                      ),
                                    ),
                                  );
                                }
                              },
                      ),
                      const SizedBox(width: 12),
                      _RoundAction(
                        icon: Icons.shuffle_rounded,
                        color: player.isShuffled
                            ? context.accent
                            : YomiColors.textPrimary,
                        tooltip: 'Shuffle',
                        onTap: songs.isEmpty
                            ? null
                            : () async {
                                await player.playQueue(songs);
                                if (!player.isShuffled)
                                  await player.toggleShuffle();
                              },
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: songs.isEmpty
                            ? null
                            : () {
                                HapticFeedback.mediumImpact();
                                player.playQueue(songs);
                              },
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: context.accent,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.black,
                            size: 38,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (snapshot.connectionState != ConnectionState.done)
                  const SongListSkeleton(rows: 6),
                if (snapshot.hasError)
                  ErrorView(error: snapshot.error!, onRetry: _reload),
                if (snapshot.connectionState == ConnectionState.done &&
                    songs.isEmpty &&
                    !snapshot.hasError)
                  Padding(
                    padding: const EdgeInsets.all(48),
                    child: Center(
                      child: Text(
                        'Nothing here yet.',
                        style: yomiText(
                          14,
                          weight: FontWeight.w500,
                          color: YomiColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                for (var i = 0; i < songs.length; i++)
                  widget.playlist == null
                      ? SongTile(
                          song: songs[i],
                          onTap: () => player.playQueue(songs, startIndex: i),
                        )
                      : Dismissible(
                          key: ValueKey('${songs[i].id}-$i'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red.shade900,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 24),
                            child: const Icon(
                              Icons.remove_circle_outline_rounded,
                            ),
                          ),
                          onDismissed: (_) async {
                            await client.removeFromPlaylist(
                              widget.playlist!.id,
                              [i],
                            );
                            _reload();
                          },
                          child: SongTile(
                            song: songs[i],
                            onTap: () => player.playQueue(songs, startIndex: i),
                          ),
                        ),
                const SizedBox(height: 32),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.color = YomiColors.textPrimary,
    this.isBusy = false,
    this.progress = 0,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final Color color;
  final bool isBusy;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.10),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isBusy)
                SizedBox(
                  width: 50,
                  height: 50,
                  child: CircularProgressIndicator(
                    value: progress > 0 && progress < 1 ? progress : null,
                    strokeWidth: 2.5,
                    color: context.accent,
                  ),
                ),
              Icon(icon, color: color, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// An artist is just their songs, in the same layout as a playlist.
void openArtist(BuildContext context, Artist artist) {
  final client = context.read<SessionController>().client;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CollectionPage(
        title: artist.name,
        subtitle: '',
        loadSongs: () => client.artistSongs(artist.id),
      ),
    ),
  );
}

void openPlaylist(BuildContext context, Playlist playlist) {
  final client = context.read<SessionController>().client;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CollectionPage(
        title: playlist.name,
        subtitle: '${playlist.songCount} songs',
        coverArtId: playlist.coverArtId,
        playlist: playlist,
        loadSongs: () => client.playlistSongs(playlist.id),
      ),
    ),
  );
}
