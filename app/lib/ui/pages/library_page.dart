import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/subsonic_client.dart';
import '../../state/connectivity_controller.dart';
import '../../state/download_manager.dart';
import '../../state/imports_controller.dart';
import '../../state/offline_keeper.dart';
import '../../state/session.dart';
import '../../state/settings.dart';
import '../imports/imported_playlist_page.dart';
import '../library/library_items.dart';
import '../library/library_list.dart';
import '../library/library_tiles.dart';
import '../settings/profile_section.dart';
import '../stats/spotify_import_page.dart';
import '../theme.dart';
import '../widgets/async_section.dart';
import '../widgets/downloaded_songs.dart';
import '../widgets/error_view.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/profile_panel.dart';
import '../widgets/shimmer.dart';
import 'collection_page.dart';
import '../widgets/yomi_refresh.dart';

enum _NewKind { empty, spotify }

const Duration _searchDebounce = Duration(milliseconds: 300);

/// Your Library, laid out like Spotify's: filter chips, a sort and view switch, then
/// Liked songs, your playlists and (under their chip) artists.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late LibraryFilter? _filter = context.read<ConnectivityController>().isOffline
      ? LibraryFilter.downloaded
      : null;

  bool _isSearching = false;
  String _query = '';
  Timer? _debounce;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _query = '';
        _searchController.clear();
      }
    });
  }

  void _startNew(_NewKind kind) {
    switch (kind) {
      case _NewKind.empty:
        unawaited(_newPlaylist());
      case _NewKind.spotify:
        unawaited(
          Navigator.of(context)
              .push(yomiRoute<void>(builder: (_) => const SpotifyImportPage())),
        );
    }
  }

  Future<void> _newPlaylist() async {
    final session = context.read<SessionController>();
    final name = await promptForName(context);
    if (name == null || name.isEmpty) return;
    try {
      await session.client.createPlaylist(name);
      await session.client.refreshPlaylists();
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failureMessage(context, error))));
      }
    }
  }

  void _open(LibraryItem item) {
    final client = context.read<SessionController>().client;
    final navigator = Navigator.of(context);
    switch (item) {
      case LikedSongsItem():
        navigator.push(
          yomiRoute<void>(
            builder: (_) => CollectionPage(
              title: 'Liked songs',
              subtitle: '',
              kind: CollectionKind.playlist,
              tint: context.accentDeep,
              cover: (size) => LikedSongsCover(size: size),
              loadSongs: client.starredSongs,
              onAddSong: (song) => client.star(song.id),
            ),
          ),
        );
      case DownloadedSongsItem():
        navigator.push(
          yomiRoute<void>(builder: (_) => const _DownloadedSongsPage()),
        );
      case PlaylistItem(:final playlist):
        openPlaylist(context, playlist);
      case ImportedItem(:final playlist):
        navigator.push(
          yomiRoute<void>(
            builder: (_) => ImportedPlaylistPage(playlistId: playlist.id),
          ),
        );
      case ArtistItem(:final artist):
        openArtist(context, artist);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = context.read<SessionController>().client;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          if (_isSearching) _searchField(),
          _FilterChips(
            selected: _filter,
            onChanged: (filter) => setState(() => _filter = filter),
          ),
          const _SortBar(),
          Expanded(child: _items(client)),
        ],
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(kPagePadding, 18, YomiSpace.xs, 10),
    child: Row(
      children: [
        Semantics(
          button: true,
          label: 'Profile and settings',
          child: GestureDetector(
            onTap: () => openProfilePanel(context),
            child: const ProfileAvatar(size: 36),
          ),
        ),
        const SizedBox(width: YomiSpace.m),
        Expanded(
          child: Text(
            'Your Library',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: yomiText(24, weight: FontWeight.w800, letterSpacing: -0.6),
          ),
        ),
        IconButton(
          icon: Icon(
            _isSearching ? Icons.close_rounded : Icons.search_rounded,
            size: 28,
          ),
          tooltip: 'Search your library',
          onPressed: _toggleSearch,
        ),
        PopupMenuButton<_NewKind>(
          icon: const Icon(Icons.add_rounded, size: 32),
          tooltip: 'Create',
          onSelected: _startNew,
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _NewKind.empty,
              child: ListTile(
                leading: Icon(Icons.playlist_add_rounded),
                title: Text('New playlist'),
              ),
            ),
            PopupMenuItem(
              value: _NewKind.spotify,
              child: ListTile(
                leading: Icon(Icons.download_rounded),
                title: Text('Import from Spotify'),
                subtitle: Text('Link or export file, same order'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 10),
    child: TextField(
      controller: _searchController,
      autofocus: true,
      onChanged: _onQueryChanged,
      textInputAction: TextInputAction.search,
      decoration: const InputDecoration(
        hintText: 'Search your library',
        prefixIcon: Icon(Icons.search_rounded),
        isDense: true,
      ),
    ),
  );

  /// Artists are fetched only when they can show: under their chip, or in a search.
  Widget _items(SubsonicClient client) {
    final needsArtists =
        _filter == LibraryFilter.artists ||
        (_filter == null && _query.isNotEmpty);
    return AsyncSection<List<Playlist>>(
      initialData: client.cachedPlaylists,
      reloadKey: client.baseUrl,
      refreshOn: client.catalogUpdates,
      refreshEndpoints: const {'getPlaylists'},
      skeleton: const SongListSkeleton(rows: 6),
      load: client.playlists,
      builder: (context, playlists) => needsArtists
          ? AsyncSection<List<Artist>>(
              initialData: client.cachedArtists,
              reloadKey: client.baseUrl,
              refreshOn: client.catalogUpdates,
              refreshEndpoints: const {'getArtists'},
              load: client.artists,
              builder: (context, artists) =>
                  _list(context, client, playlists, artists),
            )
          : _list(context, client, playlists, const []),
    );
  }

  /// Built with the [context] of the section that loaded the data, so its providers
  /// are listened to from the widget that's actually building.
  Widget _list(
    BuildContext context,
    SubsonicClient client,
    List<Playlist> playlists,
    List<Artist> artists,
  ) {
    final settings = context.watch<SettingsController>();
    final keeper = context.watch<OfflineKeeper>();
    final sort = LibrarySort.byName(settings.librarySort);
    final items = buildLibraryItems(
      filter: _filter,
      query: _query,
      sort: sort,
      me: context.read<SessionController>().username,
      playlists: settings.orderPlaylists(playlists),
      imported: context.watch<ImportsController>().playlists,
      artists: artists,
      isKept: keeper.isKept,
      downloadedCount: context.select<DownloadManager, int>(
        (d) => d.downloadedSongs.length,
      ),
    );
    final canReorder =
        sort == LibrarySort.custom &&
        _query.isEmpty &&
        _filter != LibraryFilter.artists &&
        !settings.libraryIsGrid;
    return YomiRefresh(
      onRefresh: client.refreshPlaylists,
      child: LibraryList(
        items: items,
        isGrid: settings.libraryIsGrid,
        canReorder: canReorder,
        emptyText: _query.isEmpty
            ? 'Nothing here yet'
            : 'Nothing in your library matches "$_query"',
        onOpen: _open,
        onReorder: (ordered) =>
            settings.setPlaylistOrder([for (final p in ordered) p.id]),
      ),
    );
  }
}

/// Playlists, Artists, Downloaded. Picking one shows an ✕ to go back to everything.
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onChanged});

  final LibraryFilter? selected;
  final ValueChanged<LibraryFilter?> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = selected;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
        children: [
          if (current != null)
            Padding(
              padding: const EdgeInsets.only(right: YomiSpace.s),
              child: _Pill(
                semanticLabel: 'Show everything',
                onTap: () => onChanged(null),
                child: const Icon(Icons.close_rounded, size: 18),
              ),
            ),
          for (final filter in LibraryFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: YomiSpace.s),
              child: _Pill(
                isSelected: filter == current,
                onTap: () => onChanged(filter == current ? null : filter),
                child: Text(filter.label),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.onTap,
    required this.child,
    this.isSelected = false,
    this.semanticLabel,
  });

  final VoidCallback onTap;
  final Widget child;
  final bool isSelected;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final foreground = isSelected ? context.onAccent : YomiColors.textPrimary;
    return Semantics(
      button: true,
      selected: isSelected,
      label: semanticLabel,
      child: Material(
        color: isSelected ? context.accent : YomiColors.surfaceHigh,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(color: foreground),
                child: DefaultTextStyle.merge(
                  style: yomiText(
                    14,
                    weight: FontWeight.w600,
                    color: foreground,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "⇅ Custom order" on the left, the list/grid switch on the right.
class _SortBar extends StatelessWidget {
  const _SortBar();

  Future<void> _chooseSort(BuildContext context, LibrarySort current) {
    final settings = context.read<SettingsController>();
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, YomiSpace.s),
              child: Text(
                'Sort by',
                style: yomiText(18, weight: FontWeight.w800),
              ),
            ),
            for (final sort in LibrarySort.values)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text(
                  sort.label,
                  style: yomiText(
                    16,
                    weight: FontWeight.w600,
                    color: sort == current
                        ? context.accent
                        : YomiColors.textPrimary,
                  ),
                ),
                trailing: sort == current
                    ? Icon(Icons.check_rounded, color: context.accent)
                    : null,
                onTap: () {
                  Navigator.pop(sheet);
                  settings.setLibrarySort(sort.name);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final sort = LibrarySort.byName(settings.librarySort);
    final isGrid = settings.libraryIsGrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(YomiSpace.s, YomiSpace.s, 4, 0),
      child: Row(
        children: [
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: YomiColors.textPrimary,
            ),
            onPressed: () => _chooseSort(context, sort),
            icon: const Icon(Icons.swap_vert_rounded, size: 20),
            label: Text(
              sort.label,
              style: yomiText(14, weight: FontWeight.w600),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: isGrid ? 'Show as list' : 'Show as grid',
            icon: Icon(
              isGrid ? Icons.view_list_rounded : Icons.grid_view_rounded,
              size: 22,
            ),
            onPressed: () => settings.setLibraryIsGrid(!isGrid),
          ),
        ],
      ),
    );
  }
}

/// Every song saved on this device, from the library's Downloaded songs row.
class _DownloadedSongsPage extends StatelessWidget {
  const _DownloadedSongsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloaded songs')),
      body: const DownloadedSongs(),
    );
  }
}
