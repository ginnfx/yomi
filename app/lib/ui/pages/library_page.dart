import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/genres.dart';
import '../../core/models.dart';
import '../../core/song_sort.dart';
import '../../core/taste.dart';
import '../../core/spotify/imported_playlist.dart';
import '../../core/subsonic_client.dart';
import '../../state/catalog_controller.dart';
import '../../state/connectivity_controller.dart';
import '../../state/home_controller.dart';
import '../../state/imports_controller.dart';
import '../../state/player_controller.dart';
import '../../state/settings.dart';
import '../../state/session.dart';
import '../imports/imported_playlist_page.dart';
import '../theme.dart';
import '../widgets/async_section.dart';
import '../widgets/cover_art.dart';
import '../widgets/downloaded_songs.dart';
import '../widgets/error_view.dart';
import '../stats/spotify_import_page.dart';
import '../widgets/genre_filter_bar.dart';
import '../widgets/made_for_you.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/shimmer.dart';
import '../widgets/song_tile.dart';
import 'collection_page.dart';
import 'settings_page.dart';

bool _matches(String text, String query) =>
    query.isEmpty || text.toLowerCase().contains(query.toLowerCase());

enum _Tab { playlists, songs, artists, downloaded }

enum _NewKind { empty, spotify }

/// The most songs one tap queues. Playing the whole library at once would make every
/// later queue change slow, and nobody hears 500 songs in a sitting.
const int _maxQueueSize = 500;

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late _Tab _tab = context.read<ConnectivityController>().isOffline
      ? _Tab.downloaded
      : _Tab.songs;
  late final Set<_Tab> _visited = {_tab};

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
    _debounce = Timer(const Duration(milliseconds: 300), () {
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
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SpotifyImportPage()),
          ),
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
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(describeFailure(context, error).title)),
        );
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
          Padding(
            padding: const EdgeInsets.fromLTRB(kPagePadding, 22, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Library',
                    style: yomiText(
                      36,
                      weight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _isSearching ? Icons.close_rounded : Icons.search_rounded,
                  ),
                  tooltip: 'Search library',
                  onPressed: _toggleSearch,
                ),
                PopupMenuButton<_NewKind>(
                  icon: const Icon(Icons.add_rounded, size: 30),
                  tooltip: 'New playlist',
                  onSelected: _startNew,
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: _NewKind.empty,
                      child: ListTile(
                        leading: Icon(Icons.playlist_add_rounded),
                        title: Text('New playlist'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _NewKind.spotify,
                      child: ListTile(
                        leading: Icon(Icons.download_rounded),
                        title: Text('Import from Spotify'),
                        subtitle: Text('Link or export file, same order'),
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.tune_rounded),
                  tooltip: 'Settings',
                  onPressed: () => openSettings(context),
                ),
              ],
            ),
          ),
          if (_isSearching)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                0,
                kPagePadding,
                10,
              ),
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
            ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
              children: [
                for (final tab in _Tab.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: ChoiceChip(
                      avatar: tab == _Tab.downloaded
                          ? Icon(
                              Icons.arrow_circle_down_rounded,
                              size: 18,
                              color: _tab == tab
                                  ? Colors.black
                                  : YomiColors.success,
                            )
                          : null,
                      label: Text(switch (tab) {
                        _Tab.playlists => 'Playlists',
                        _Tab.songs => 'Songs',
                        _Tab.artists => 'Artists',
                        _Tab.downloaded => 'On this device',
                      }),
                      selected: _tab == tab,
                      showCheckmark: false,
                      selectedColor: context.accent,
                      backgroundColor: YomiColors.surfaceHigh,
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      labelStyle: yomiText(
                        14,
                        weight: FontWeight.w700,
                        color: _tab == tab
                            ? Colors.black
                            : YomiColors.textPrimary,
                      ),
                      onSelected: (_) => setState(() {
                        _tab = tab;
                        _visited.add(tab);
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            // Each tab stays alive once opened, keeping its list and scroll position.
            child: _query.isEmpty
                ? IndexedStack(
                    index: _tab.index,
                    children: [
                      for (final tab in _Tab.values)
                        _visited.contains(tab)
                            ? _body(tab, client)
                            : const SizedBox.shrink(),
                    ],
                  )
                : KeyedSubtree(
                    key: ValueKey('$_tab-$_query'),
                    child: _body(_tab, client),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _body(_Tab tab, SubsonicClient client) => switch (tab) {
    _Tab.playlists => _PlaylistsTab(client: client, query: _query),
    _Tab.songs =>
      _query.isEmpty ? const _SongsTab() : _SongSearch(query: _query),
    _Tab.artists => AsyncSection<List<Artist>>(
      initialData: client.cachedArtists,
      reloadKey: client.baseUrl,
      refreshOn: client.catalogUpdates,
      refreshEndpoints: const {'getArtists'},
      load: client.artists,
      builder: (context, all) {
        final artists = all.where((a) => _matches(a.name, _query)).toList();
        return _pullToRefresh(
          onRefresh: client.refreshArtists,
          child: ListView.builder(
            itemCount: artists.length,
            itemBuilder: (context, i) => ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: kPagePadding,
                vertical: 4,
              ),
              leading: ArtistAvatar(
                artistId: artists[i].id,
                name: artists[i].name,
                size: 56,
              ),
              title: Text(
                artists[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: yomiText(16, weight: FontWeight.w700),
              ),
              onTap: () => openArtist(context, artists[i]),
            ),
          ),
        );
      },
    ),
    _Tab.downloaded => DownloadedSongs(query: _query),
  };
}

Widget _pullToRefresh({
  required Future<void> Function() onRefresh,
  required Widget child,
}) => RefreshIndicator(onRefresh: onRefresh, child: child);

/// Every song in the library, read from the copy saved on this device.
class _SongsTab extends StatefulWidget {
  const _SongsTab();

  @override
  State<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends State<_SongsTab> {
  List<GenreGroup> _genres = const [];
  Set<String> _selectedGenres = const {};
  List<Song> _filterSource = const [];
  Set<String> _filterSelection = const {};
  List<Song> _filtered = const [];
  SongSort _sort = SongSort.recentlyAdded;
  bool _likedOnly = false;
  bool _unplayedOnly = false;
  List<Song>? _shown;
  Object? _shownKey;

  /// Filtered and sorted, worked out again only when something it depends on changes.
  List<Song> _ordered(List<Song> base, TasteProfile taste) {
    final key = (base, _sort, _likedOnly, _unplayedOnly, taste);
    final shown = _shown;
    if (shown != null && _sameKey(key, _shownKey)) return shown;
    _shownKey = key;
    return _shown = sortSongs(
      filterSongs(base, likedOnly: _likedOnly, unplayedOnly: _unplayedOnly),
      _sort,
      taste: taste,
    );
  }

  static bool _sameKey(
    (List<Song>, SongSort, bool, bool, TasteProfile) key,
    Object? other,
  ) =>
      other is (List<Song>, SongSort, bool, bool, TasteProfile) &&
      identical(key.$1, other.$1) &&
      key.$2 == other.$2 &&
      key.$3 == other.$3 &&
      key.$4 == other.$4 &&
      identical(key.$5, other.$5);

  @override
  void initState() {
    super.initState();
    unawaited(_loadGenres());
    final catalog = context.read<CatalogController>();
    if (!catalog.isLoaded) unawaited(catalog.sync());
  }

  Future<void> _loadGenres() async {
    try {
      final genres = await context.read<SessionController>().client.genres();
      if (mounted) setState(() => _genres = groupGenres(genres));
    } on Object catch (error) {
      // Filtering is optional; the list works without it.
      debugPrint('Could not load genres: $error');
    }
  }

  /// Worked out again only when the songs or the chosen genres change.
  List<Song> _songsFrom(List<Song> all) {
    if (_selectedGenres.isEmpty) return all;
    if (identical(all, _filterSource) &&
        identical(_selectedGenres, _filterSelection)) {
      return _filtered;
    }
    final variants = {
      for (final group in _genres)
        if (_selectedGenres.contains(group.name)) ...group.variants,
    };
    _filterSource = all;
    _filterSelection = _selectedGenres;
    _filtered = List.unmodifiable(
      all.where((song) => variants.contains(song.genre)),
    );
    return _filtered;
  }

  /// A queue that starts at the tapped song, so a huge library stays quick to play.
  void _playFrom(PlayerController player, List<Song> songs, int index) {
    player.playQueue(songs.skip(index).take(_maxQueueSize).toList());
  }

  Future<void> _shuffle(PlayerController player, List<Song> songs) async {
    await player.playQueue(
      ([...songs]..shuffle()).take(_maxQueueSize).toList(),
    );
    if (!player.isShuffled) await player.toggleShuffle();
  }

  Widget _actions(PlayerController player, List<Song> songs) => Padding(
    padding: const EdgeInsets.fromLTRB(kPagePadding, 4, kPagePadding, 10),
    child: Row(
      children: [
        FilledButton.icon(
          onPressed: songs.isEmpty ? null : () => _playFrom(player, songs, 0),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Play'),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            side: BorderSide(color: YomiColors.faint(0.24)),
          ),
          onPressed: songs.isEmpty ? null : () => _shuffle(player, songs),
          icon: const Icon(Icons.shuffle_rounded),
          label: Text('Shuffle', style: yomiText(15, weight: FontWeight.w700)),
        ),
        const Spacer(),
        PopupMenuButton<SongSort>(
          tooltip: 'Sort songs',
          initialValue: _sort,
          onSelected: (sort) => setState(() => _sort = sort),
          itemBuilder: (_) => [
            for (final sort in SongSort.values)
              PopupMenuItem(value: sort, child: Text(sort.label)),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort_rounded, size: 18),
              const SizedBox(width: 4),
              Text(_sort.label, style: yomiText(13, weight: FontWeight.w700)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _quickFilters() => SizedBox(
    height: 40,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
      children: [
        FilterChip(
          label: const Text('Liked'),
          selected: _likedOnly,
          onSelected: (on) => setState(() => _likedOnly = on),
        ),
        const SizedBox(width: 8),
        FilterChip(
          label: const Text('Not played yet'),
          selected: _unplayedOnly,
          onSelected: (on) => setState(() => _unplayedOnly = on),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    final catalog = context.watch<CatalogController>();
    final error = catalog.error;
    if (!catalog.isLoaded) {
      return error == null
          ? const SongListSkeleton(rows: 8)
          : ListView(
              children: [ErrorView(error: error, onRetry: catalog.sync)],
            );
    }
    final songs = _ordered(
      _songsFrom(catalog.songs),
      context.watch<HomeController>().taste,
    );
    return _pullToRefresh(
      onRefresh: () => catalog.sync(force: true),
      child: ListView.builder(
        itemCount: songs.length + 2,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(
              children: [
                _actions(player, songs),
                _quickFilters(),
                const SizedBox(height: 6),
                GenreFilterBar(
                  groups: _genres,
                  selected: _selectedGenres,
                  onChanged: (selected) =>
                      setState(() => _selectedGenres = selected),
                ),
                const SizedBox(height: YomiSpace.s),
              ],
            );
          }
          if (i == songs.length + 1) return const SizedBox(height: 8);
          final song = songs[i - 1];
          return SongTile(
            key: ValueKey(song.id),
            song: song,
            onTap: () => _playFrom(player, songs, i - 1),
          );
        },
      ),
    );
  }
}

class _PlaylistsTab extends StatefulWidget {
  const _PlaylistsTab({required this.client, this.query = ''});

  final SubsonicClient client;
  final String query;

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> {
  List<Playlist>? _source;
  List<Playlist>? _ordered;

  /// The first cover among an imported playlist's songs that are in the library.
  String? _firstCover(ImportedPlaylist playlist) {
    final byId = {
      for (final song in context.read<CatalogController>().songs) song.id: song,
    };
    for (final entry in playlist.entries) {
      final cover = byId[entry.songId]?.coverArtId;
      if (cover != null) return cover;
    }
    return null;
  }

  void _reorder(int from, int to) {
    final list = [..._ordered!];
    list.insert(to, list.removeAt(from));
    setState(() => _ordered = list);
    context.read<SettingsController>().setPlaylistOrder([
      for (final p in list) p.id,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsController>();
    final client = widget.client;
    return AsyncSection<List<Playlist>>(
      initialData: client.cachedPlaylists,
      reloadKey: client.baseUrl,
      refreshOn: client.catalogUpdates,
      refreshEndpoints: const {'getPlaylists'},
      skeleton: const SongListSkeleton(rows: 6),
      load: client.playlists,
      builder: (context, loaded) {
        if (!identical(loaded, _source)) {
          _source = loaded;
          _ordered = settings.orderPlaylists(loaded);
        }
        final imported = [
          for (final playlist in context.watch<ImportsController>().playlists)
            if (_matches(playlist.name, widget.query)) playlist,
        ];
        final isFiltering = widget.query.isNotEmpty;
        final shown = [
          for (final p in _ordered!)
            if (_matches(p.name, widget.query)) p,
        ];
        return ListView(
          children: [
            if (widget.query.isEmpty) const MadeForYou(),
            for (final playlist in imported)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: kPagePadding,
                  vertical: 4,
                ),
                leading: PlaylistCover(
                  playlistId: playlist.id,
                  coverArtId: _firstCover(playlist),
                  size: 56,
                  seed: playlist.name,
                ),
                title: Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(16, weight: FontWeight.w700),
                ),
                subtitle: Text('Playlist · ${playlist.entries.length} songs'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ImportedPlaylistPage(playlistId: playlist.id),
                  ),
                ),
              ),
            if (!isFiltering)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: kPagePadding,
                  vertical: 4,
                ),
                leading: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      colors: [context.accentDeep, context.accentSecondary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: Colors.black,
                  ),
                ),
                title: Text(
                  'Liked songs',
                  style: yomiText(16, weight: FontWeight.w700),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CollectionPage(
                      title: 'Liked songs',
                      subtitle: '',
                      loadSongs: client.starredSongs,
                    ),
                  ),
                ),
              ),
            if (_ordered!.isEmpty)
              Padding(
                padding: const EdgeInsets.all(40),
                child: Text(
                  'No playlists yet',
                  textAlign: TextAlign.center,
                  style: yomiText(
                    14,
                    weight: FontWeight.w500,
                    color: YomiColors.textSecondary,
                  ),
                ),
              ),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: isFiltering ? (_, _) {} : _reorder,
              proxyDecorator: (child, _, _) => Material(
                color: Colors.transparent,
                elevation: 6,
                child: child,
              ),
              itemCount: shown.length,
              itemBuilder: (context, i) {
                final playlist = shown[i];
                final tile = ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: kPagePadding,
                    vertical: 4,
                  ),
                  leading: PlaylistCover(
                    playlistId: playlist.id,
                    coverArtId: playlist.coverArtId,
                    size: 56,
                    seed: playlist.name,
                  ),
                  title: Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: yomiText(16, weight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    '${playlist.songCount} songs',
                    style: yomiText(
                      13,
                      weight: FontWeight.w500,
                      color: YomiColors.textSecondary,
                    ),
                  ),
                  onTap: () => openPlaylist(context, playlist),
                );
                return KeyedSubtree(
                  key: ValueKey(playlist.id),
                  child: isFiltering
                      ? tile
                      : ReorderableDelayedDragStartListener(
                          index: i,
                          child: tile,
                        ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// Songs matching a typed query, asked of the server so the whole library is searched.
class _SongSearch extends StatelessWidget {
  const _SongSearch({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final client = context.read<SessionController>().client;
    final player = context.read<PlayerController>();
    final catalog = context.read<CatalogController>();
    return AsyncSection<List<Song>>(
      initialData: catalog.isLoaded
          ? catalog.searchIndex.search(query).songs
          : null,
      load: () async => catalog.isLoaded
          ? catalog.searchIndex.search(query).songs
          : (await client.search(query, count: 100)).songs,
      builder: (context, songs) {
        if (songs.isEmpty)
          return Center(
            child: Text(
              'No songs match "$query"',
              style: yomiText(
                14,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
          );
        return ListView.builder(
          itemCount: songs.length,
          itemBuilder: (context, i) => SongTile(
            song: songs[i],
            onTap: () => player.playQueue(songs, startIndex: i),
          ),
        );
      },
    );
  }
}
