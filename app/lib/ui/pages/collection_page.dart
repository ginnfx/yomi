import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/download_manager.dart';
import '../../state/offline_keeper.dart';
import '../../state/player_controller.dart';
import '../../state/playlist_covers_controller.dart';
import '../../state/session.dart';
import '../settings/profile_section.dart';
import '../theme.dart';
import '../widgets/action_sheet.dart';
import '../widgets/add_songs_sheet.dart';
import '../widgets/cover_art.dart';
import '../widgets/download_toggle.dart';
import '../widgets/cover_color.dart';
import '../widgets/error_view.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/playlist_recommendations.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/send_to_sheet.dart';
import '../widgets/shimmer.dart';
import '../widgets/song_tile.dart';
import 'collection_header.dart';
import 'reorder_page.dart';

/// How far past the big cover the page scrolls before the bar's title is fully shown.
const double _titleFadeDistance = 80;

/// The header's colour while the cover's own colour is still being worked out.
const Color _waitingColor = Color(0xFF2A2A2A);

/// What this page's songs are read from.
const Set<String> _songEndpoints = {
  'getAlbum',
  'getArtist',
  'getPlaylist',
  'getStarred2',
};

/// An artist's page can refresh many albums at once, so these become one reload.
const Duration _reloadDelay = Duration(milliseconds: 500);

/// How tall the header-coloured fill behind the list must be. When the list is pulled past
/// its top by `-offset`, the pinned bar stays put and the header slides down below it, so
/// the gap runs from the bar's bottom to that far below it. Nothing is needed otherwise.
double overscrollFillHeight({
  required double offset,
  required double barHeight,
}) => offset < 0 ? barHeight - offset : 0;

/// An album, a playlist, or Liked songs: coloured header, play controls, and the tracks.
class CollectionPage extends StatefulWidget {
  const CollectionPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.loadSongs,
    this.savedSongs,
    this.coverArtId,
    this.playlist,
    this.kind = CollectionKind.list,
    this.tint,
    this.cover,
    this.onAddSong,
  });

  /// The header's colour when there's no cover to take it from, as for Liked songs.
  final Color? tint;

  /// A cover of its own at the given size, instead of the album art.
  final Widget Function(double size)? cover;

  /// Named under the title ("Album"). Playlists are known from [playlist].
  final CollectionKind kind;

  final String title;
  final String subtitle;
  final String? coverArtId;
  final Future<List<Song>> Function() loadSongs;

  /// What's already saved on this device, shown straight away while [loadSongs] runs.
  final List<Song>? savedSongs;

  /// Adds a song to a list that isn't a playlist, such as liking one for Liked songs.
  /// Playlists add through the server's playlist call instead.
  final Future<void> Function(Song song)? onAddSong;

  /// Set for editable playlists: enables swipe-to-remove, rename and delete.
  final Playlist? playlist;

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  late Future<List<Song>> _songs = widget.loadSongs();
  late List<Song>? _lastSongs = widget.savedSongs;
  late String _title = widget.title;
  int _dismissalEpoch = 0;

  StreamSubscription<String>? _updates;
  Timer? _reloadTimer;
  final _scroll = ScrollController();
  final _barTitle = ValueNotifier<double>(0);

  void _reload() => setState(() => _songs = widget.loadSongs());

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Opening this may show a saved list while a newer one is fetched. Show that when it
    // arrives, rather than leaving the old list up until the page is opened again.
    _updates = context.read<SessionController>().client.catalogUpdates.listen((
      endpoint,
    ) {
      if (!_songEndpoints.contains(endpoint)) return;
      _reloadTimer?.cancel();
      _reloadTimer = Timer(_reloadDelay, () {
        if (mounted) _reload();
      });
    });
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    unawaited(_updates?.cancel());
    _scroll.dispose();
    _barTitle.dispose();
    super.dispose();
  }

  Future<void> _changePicture() =>
      pickPlaylistPicture(context, widget.playlist!.id);

  Future<void> _changeOrder() async {
    final messenger = ScaffoldMessenger.of(context);
    final client = context.read<SessionController>().client;
    final songs = await _songs;
    if (!mounted || songs.length < 2) return;
    final order = await reorderSongs(
      context,
      title: _title,
      items: [
        for (final song in songs)
          ReorderItem(
            title: song.title,
            subtitle: song.artist,
            coverArtId: song.coverArtId,
          ),
      ],
    );
    if (order == null) return;
    try {
      await client.replacePlaylistSongs(widget.playlist!.id, [
        for (final i in order) songs[i].id,
      ]);
      if (mounted) _reload();
    } on Exception catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(failureMessage(context, error))),
      );
    }
  }

  Future<void> _removePicture() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<PlaylistCoversController>().removeCover(
        widget.playlist!.id,
      );
    } on Object catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(failureMessage(context, error))),
        );
      }
    }
  }

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

  void _onScroll() {
    final fadeStart = headerCoverSize(MediaQuery.sizeOf(context).width);
    final shown = ((_scroll.offset - fadeStart) / _titleFadeDistance).clamp(
      0.0,
      1.0,
    );
    if (shown != _barTitle.value) _barTitle.value = shown;
  }

  String? _pictureUrl() {
    final playlist = widget.playlist;
    if (playlist == null) return null;
    try {
      return context.watch<PlaylistCoversController>().urlFor(playlist.id);
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _toggleDownload(List<Song> songs, bool isFullySaved) =>
      toggleSongsDownload(context, songs, isFullySaved: isFullySaved);

  Future<void> _play(PlayerController player, List<Song> songs) async {
    final current = player.current;
    final isFromHere =
        current != null && songs.any((song) => song.id == current.id);
    if (isFromHere) return player.togglePlay();
    await player.playQueue(songs);
  }

  Future<bool> _removeAt(List<Song> songs, int index) async {
    try {
      await context.read<SessionController>().client.removeSongFromPlaylist(
        widget.playlist!.id,
        songs[index],
        index,
      );
      return true;
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failureMessage(context, error))));
      }
      return false;
    }
  }

  void _hideRemoved(List<Song> songs, int index) {
    if (!mounted) return;
    final remaining = [...songs]..removeAt(index);
    setState(() {
      _dismissalEpoch++;
      _lastSongs = remaining;
      _songs = Future.value(remaining);
    });
  }

  void _openPlaylistMenu(List<Song> songs, String? pictureUrl) {
    final playlist = widget.playlist!;
    final keeper = context.read<OfflineKeeper>();
    final isKept = keeper.isKept(playlist);
    final hasPicture = context.read<PlaylistCoversController>().hasCover(
      playlist.id,
    );
    unawaited(
      showActionSheet(
        context,
        coverArtId: widget.coverArtId,
        imageUrl: pictureUrl,
        header: SheetHeader(
          cover: PlaylistCover(
            playlistId: playlist.id,
            coverArtId: widget.coverArtId,
            songs: songs,
            size: 52,
            radius: YomiRadius.art,
            seed: _title,
          ),
          title: _title,
          subtitle: '${songs.length} songs',
        ),
        actions: [
          SheetAction(
            icon: Icons.send_rounded,
            label: 'Send to…',
            onSelected: () =>
                showSendTo(context, title: _title, playlistId: playlist.id),
          ),
          SheetAction(
            icon: isKept
                ? Icons.cloud_done_outlined
                : Icons.cloud_download_outlined,
            label: isKept ? 'Keep offline · On' : 'Keep offline · Off',
            onSelected: () => keeper.setKept(playlist, !isKept),
          ),
          SheetAction(
            icon: Icons.image_outlined,
            label: 'Choose picture',
            onSelected: _changePicture,
          ),
          if (hasPicture)
            SheetAction(
              icon: Icons.hide_image_outlined,
              label: 'Remove picture',
              onSelected: _removePicture,
            ),
          SheetAction(
            icon: Icons.swap_vert_rounded,
            label: 'Change order',
            onSelected: _changeOrder,
          ),
          SheetAction(
            icon: Icons.edit_outlined,
            label: 'Rename',
            onSelected: _rename,
          ),
          SheetAction(
            icon: Icons.delete_outline_rounded,
            label: 'Delete playlist',
            onSelected: _delete,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pictureUrl = _pictureUrl();
    return FutureBuilder<List<Song>>(
      future: _songs,
      builder: (context, snapshot) {
        final loaded = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        if (loaded != null) _lastSongs = loaded;
        final known = _lastSongs;
        final songs = known ?? const <Song>[];
        final coverArtId = widget.coverArtId ?? songs.firstOrNull?.coverArtId;
        return CoverColorBuilder(
          coverArtId: coverArtId,
          imageUrl: pictureUrl,
          builder: (context, found) {
            final color = Color.lerp(
              context.pageColor,
              widget.tint ?? found ?? _waitingColor,
              headerTintStrength,
            )!;
            return Scaffold(
              // Pulling past the top would otherwise show black above the header, so
              // the header's own colour sits behind the list to fill that gap.
              body: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: ListenableBuilder(
                      listenable: _scroll,
                      builder: (context, _) => SizedBox(
                        height: overscrollFillHeight(
                          offset: _scroll.hasClients ? _scroll.offset : 0,
                          barHeight:
                              MediaQuery.paddingOf(context).top +
                              kToolbarHeight,
                        ),
                        child: ColoredBox(color: color),
                      ),
                    ),
                  ),
                  CustomScrollView(
                    controller: _scroll,
                    slivers: [
                      _bar(color),
                      SliverToBoxAdapter(
                        child: _header(color, songs, coverArtId, pictureUrl),
                      ),
                      ..._states(snapshot, known, songs),
                      _songList(songs),
                      if (widget.playlist != null)
                        SliverToBoxAdapter(
                          child: PlaylistRecommendations(
                            key: ValueKey('recommended-${widget.playlist!.id}'),
                            songs: songs,
                            onAdd: (song) async {
                              await context
                                  .read<SessionController>()
                                  .client
                                  .addToPlaylist(widget.playlist!.id, [
                                    song.id,
                                  ]);
                              _reload();
                            },
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 32)),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// The bar stays in the cover's colour; the title fades in once the big one scrolls away.
  Widget _bar(Color color) => SliverAppBar(
    pinned: true,
    backgroundColor: color,
    surfaceTintColor: Colors.transparent,
    scrolledUnderElevation: 0,
    elevation: 0,
    leading: Padding(
      padding: const EdgeInsets.all(YomiSpace.s),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.28),
        ),
        child: const BackButton(),
      ),
    ),
    title: ValueListenableBuilder<double>(
      valueListenable: _barTitle,
      builder: (context, shown, child) => Opacity(opacity: shown, child: child),
      child: Text(
        _title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: yomiText(16, weight: FontWeight.w700),
      ),
    ),
  );

  Widget _header(
    Color color,
    List<Song> songs,
    String? coverArtId,
    String? pictureUrl,
  ) {
    final player = context.watch<PlayerController>();
    final downloads = context.watch<DownloadManager>();
    final size = headerCoverSize(MediaQuery.sizeOf(context).width);
    final playlist = widget.playlist;
    final savedCount = downloads.downloadedCountOf(songs);
    final isFullySaved = songs.isNotEmpty && savedCount == songs.length;
    final isBusy = songs.any((s) {
      final status = downloads.statusOf(s.id);
      return status == DownloadStatus.queued ||
          status == DownloadStatus.downloading;
    });
    final current = player.current;
    final isPlayingHere =
        player.isPlaying &&
        current != null &&
        songs.any((song) => song.id == current.id);
    return CollectionHeader(
      color: color,
      title: _title,
      cover:
          widget.cover?.call(size) ??
          (playlist != null
              ? PlaylistCover(
                  playlistId: playlist.id,
                  onPick: _changePicture,
                  coverArtId: coverArtId,
                  songs: songs,
                  size: size,
                  radius: YomiRadius.art,
                  elevated: true,
                  seed: _title,
                )
              : CoverArt(
                  coverArtId: coverArtId,
                  size: size,
                  radius: YomiRadius.art,
                  elevated: true,
                  seed: _title,
                )),
      byline: _byline(),
      meta: _Meta(
        kind: playlist != null ? CollectionKind.playlist : widget.kind,
        songs: songs,
        isSaved: isFullySaved,
        playlist: playlist,
      ),
      actions: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HeaderIconButton(
                icon: isFullySaved
                    ? Icons.arrow_circle_down_rounded
                    : Icons.arrow_circle_down_outlined,
                color: isFullySaved ? context.accent : null,
                tooltip: isFullySaved ? 'Remove download' : 'Download',
                progress: isBusy
                    ? (songs.isEmpty ? 0 : savedCount / songs.length)
                    : null,
                onTap: songs.isEmpty
                    ? null
                    : () => _toggleDownload(songs, isFullySaved),
              ),
              if (playlist != null)
                HeaderIconButton(
                  icon: Icons.more_horiz_rounded,
                  tooltip: 'More options',
                  onTap: () => _openPlaylistMenu(songs, pictureUrl),
                ),
              const Spacer(),
              IconButton(
                tooltip: 'Shuffle',
                iconSize: 30,
                color: player.isShuffled
                    ? context.accent
                    : YomiColors.faint(0.75),
                icon: const Icon(Icons.shuffle_rounded),
                onPressed: songs.isEmpty
                    ? null
                    : () async {
                        await player.playQueue(songs);
                        if (!player.isShuffled) await player.toggleShuffle();
                      },
              ),
              const SizedBox(width: YomiSpace.s),
              PlayButton(
                isPlaying: isPlayingHere,
                onTap: songs.isEmpty ? null : () => _play(player, songs),
              ),
            ],
          ),
          if (playlist != null || widget.onAddSong != null)
            Padding(
              padding: const EdgeInsets.only(top: YomiSpace.s),
              child: AddChip(onTap: () => _openAddSongs(songs)),
            ),
        ],
      ),
    );
  }

  Future<void> _openAddSongs(List<Song> songs) async {
    final playlist = widget.playlist;
    final client = context.read<SessionController>().client;
    await showAddSongsSheet(
      context,
      playlistName: playlist?.name ?? widget.title,
      playlistSongs: songs,
      onAdd:
          widget.onAddSong ??
          (song) => client.addToPlaylist(playlist!.id, [song.id]),
    );
    if (mounted) _reload();
  }

  /// "ginnfx" with their picture for playlists, or the album's artist.
  Widget? _byline() {
    final playlist = widget.playlist;
    if (playlist == null) {
      if (widget.subtitle.isEmpty) return null;
      return Text(
        widget.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: yomiText(14, weight: FontWeight.w700),
      );
    }
    final me = context.read<SessionController>().username;
    final owner = playlist.owner ?? me;
    return Row(
      children: [
        if (owner == me)
          const ProfileAvatar(size: 24)
        else
          CircleAvatar(
            radius: 12,
            backgroundColor: YomiColors.surfaceHigh,
            child: Text(
              owner.isEmpty ? '?' : owner.characters.first.toUpperCase(),
              style: yomiText(11, weight: FontWeight.w800),
            ),
          ),
        const SizedBox(width: YomiSpace.s),
        Flexible(
          child: Text(
            owner,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: yomiText(14, weight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  List<Widget> _states(
    AsyncSnapshot<List<Song>> snapshot,
    List<Song>? known,
    List<Song> songs,
  ) => [
    if (known == null && snapshot.connectionState != ConnectionState.done)
      const SliverToBoxAdapter(child: SongListSkeleton(rows: 6)),
    if (known == null && snapshot.hasError)
      SliverToBoxAdapter(
        child: ErrorView(error: snapshot.error!, onRetry: _reload),
      ),
    if (snapshot.connectionState == ConnectionState.done &&
        songs.isEmpty &&
        !snapshot.hasError)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Center(
            child: Text(
              widget.playlist != null
                  ? 'Add songs with the ⋯ button on any song.'
                  : 'Nothing here yet.',
              textAlign: TextAlign.center,
              style: yomiText(
                14,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
  ];

  Widget _songList(List<Song> songs) {
    final player = context.read<PlayerController>();
    final isEditable = widget.playlist != null;
    return SliverList.builder(
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final tile = SongTile(
          song: songs[i],
          onTap: () => player.playQueue(songs, startIndex: i),
          onRemoveFromPlaylist: isEditable
              ? () async {
                  if (await _removeAt(songs, i)) _hideRemoved(songs, i);
                }
              : null,
        );
        if (!isEditable) return tile;
        return Dismissible(
          key: ValueKey('$_dismissalEpoch-${songs[i].id}-$i'),
          direction: DismissDirection.endToStart,
          background: Container(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.red.shade900,
              borderRadius: BorderRadius.circular(18),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: const Icon(Icons.remove_circle_outline_rounded),
          ),
          confirmDismiss: (_) => _removeAt(songs, i),
          onDismissed: (_) => _hideRemoved(songs, i),
          child: tile,
        );
      },
    );
  }
}

/// What kind of list a page shows, named in the line under the title.
enum CollectionKind {
  playlist('Playlist'),
  album('Album'),
  artist('Artist'),
  list('');

  const CollectionKind(this.label);

  final String label;
}

/// The line under the title: "Playlist · 34 songs, 2 h 10 min", with a green arrow once
/// it's all on this device, and how far "Keep offline" has got.
class _Meta extends StatelessWidget {
  const _Meta({
    required this.kind,
    required this.songs,
    required this.isSaved,
    required this.playlist,
  });

  final CollectionKind kind;
  final List<Song> songs;
  final bool isSaved;
  final Playlist? playlist;

  @override
  Widget build(BuildContext context) {
    final style = yomiText(
      13,
      weight: FontWeight.w500,
      color: YomiColors.textSecondary,
    );
    final total = songs.fold<int>(0, (sum, s) => sum + s.durationSeconds);
    final count = songs.length == 1 ? '1 song' : '${songs.length} songs';
    final parts = [
      if (kind.label.isNotEmpty) kind.label,
      if (songs.isNotEmpty)
        '$count, ${formatTotalDuration(Duration(seconds: total))}',
    ];
    // Only playlists can be kept offline, so albums don't listen for it.
    final list = playlist;
    final keeper = list == null ? null : context.watch<OfflineKeeper>();
    final status = list != null && keeper!.isKept(list)
        ? keeper.statusOf(list.id)
        : null;
    final progress = status != null && status.saved < status.total
        ? status.isLimited
              ? '${status.saved} of ${status.total} saved, storage limit reached'
              : '${status.saved} of ${status.total} saved'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (isSaved) ...[
              Icon(
                Icons.arrow_circle_down_rounded,
                size: 16,
                color: context.accent,
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                parts.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
        ),
        if (progress != null) ...[
          const SizedBox(height: 2),
          Text(progress, style: style),
        ],
      ],
    );
  }
}

/// An album's page, from anywhere a song or album is shown.
void openAlbum(
  BuildContext context, {
  required String id,
  required String name,
  required String artist,
  String? coverArtId,
}) {
  final client = context.read<SessionController>().client;
  Navigator.of(context).push(
    yomiRoute<void>(
      builder: (_) => CollectionPage(
        title: name,
        subtitle: artist,
        coverArtId: coverArtId,
        kind: CollectionKind.album,
        savedSongs: client.cachedAlbumSongs(id),
        loadSongs: () => client.albumSongs(id),
      ),
    ),
  );
}

/// An artist is just their songs, in the same layout as a playlist.
void openArtist(BuildContext context, Artist artist) {
  final client = context.read<SessionController>().client;
  Navigator.of(context).push(
    yomiRoute<void>(
      builder: (_) => CollectionPage(
        title: artist.name,
        subtitle: '',
        kind: CollectionKind.artist,
        loadSongs: () => client.artistSongs(artist.id),
      ),
    ),
  );
}

void openPlaylist(BuildContext context, Playlist playlist) {
  final client = context.read<SessionController>().client;
  Navigator.of(context).push(
    yomiRoute<void>(
      builder: (_) => CollectionPage(
        title: playlist.name,
        subtitle: '${playlist.songCount} songs',
        coverArtId: playlist.coverArtId,
        playlist: playlist,
        loadSongs: () => client.playlistSongs(playlist.id),
        savedSongs: client.cachedPlaylistSongs(playlist.id),
      ),
    ),
  );
}
