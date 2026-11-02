import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/subsonic_client.dart';
import '../../state/connectivity_controller.dart';
import '../../state/player_controller.dart';
import '../../state/settings.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/async_section.dart';
import '../widgets/cover_art.dart';
import '../widgets/downloaded_songs.dart';
import '../widgets/error_view.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/shimmer.dart';
import '../widgets/song_tile.dart';
import 'collection_page.dart';
import 'settings_page.dart';

bool _matches(String text, String query) =>
    query.isEmpty || text.toLowerCase().contains(query.toLowerCase());

enum _Tab { playlists, songs, artists, downloaded }

const int _pageSize = 100;
const double _loadMoreThreshold = 600;

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late _Tab _tab = context.read<ConnectivityController>().isOffline
      ? _Tab.downloaded
      : _Tab.songs;
  int _reloadKey = 0;
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

  Future<void> _newPlaylist() async {
    final session = context.read<SessionController>();
    final name = await promptForName(context);
    if (name == null || name.isEmpty) return;
    try {
      await session.client.createPlaylist(name);
      if (mounted) setState(() => _reloadKey++);
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
                IconButton(
                  icon: const Icon(Icons.add_rounded, size: 30),
                  tooltip: 'New playlist',
                  onPressed: _newPlaylist,
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
                        _Tab.downloaded => 'Downloaded',
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
                      onSelected: (_) => setState(() => _tab = tab),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: KeyedSubtree(
                key: ValueKey('$_tab-$_reloadKey-$_query'),
                child: switch (_tab) {
                  _Tab.playlists => _PlaylistsTab(
                    client: client,
                    query: _query,
                  ),
                  _Tab.songs =>
                    _query.isEmpty
                        ? const _SongsTab()
                        : _SongSearch(query: _query),
                  _Tab.artists => AsyncSection<List<Artist>>(
                    load: client.artists,
                    builder: (context, all) {
                      final artists = all
                          .where((a) => _matches(a.name, _query))
                          .toList();
                      return ListView.builder(
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
                      );
                    },
                  ),
                  _Tab.downloaded => DownloadedSongs(query: _query),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Every song in the library, loaded 100 at a time as you scroll.
class _SongsTab extends StatefulWidget {
  const _SongsTab();

  @override
  State<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends State<_SongsTab> {
  final _scroll = ScrollController();
  final List<Song> _songs = [];
  Object? _error;
  bool _isLoading = false;
  bool _isDone = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < _loadMoreThreshold) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_isLoading || _isDone) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final page = await context.read<SessionController>().client.songs(
        offset: _songs.length,
        count: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _songs.addAll(page);
        _isDone = page.length < _pageSize;
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    if (_songs.isEmpty && _error != null)
      return ListView(
        children: [ErrorView(error: _error!, onRetry: _loadMore)],
      );
    if (_songs.isEmpty && _isLoading) return const SongListSkeleton(rows: 8);
    return ListView.builder(
      controller: _scroll,
      itemCount: _songs.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              4,
              kPagePadding,
              10,
            ),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _songs.isEmpty
                      ? null
                      : () => player.playQueue(_songs),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    side: const BorderSide(color: Colors.white24),
                  ),
                  onPressed: _songs.isEmpty
                      ? null
                      : () async {
                          await player.playQueue(_songs);
                          if (!player.isShuffled) await player.toggleShuffle();
                        },
                  icon: const Icon(Icons.shuffle_rounded),
                  label: Text(
                    'Shuffle',
                    style: yomiText(15, weight: FontWeight.w700),
                  ),
                ),
                const Spacer(),
                Text(
                  _isDone
                      ? '${_songs.length} songs'
                      : '${_songs.length}+ songs',
                  style: yomiText(
                    12.5,
                    weight: FontWeight.w600,
                    color: YomiColors.textSecondary,
                  ),
                ),
              ],
            ),
          );
        }
        if (i == _songs.length + 1) {
          if (_error != null)
            return ErrorView(error: _error!, onRetry: _loadMore);
          return _isLoading
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : const SizedBox(height: 8);
        }
        final song = _songs[i - 1];
        return SongTile(
          song: song,
          onTap: () => player.playQueue(_songs, startIndex: i - 1),
        );
      },
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
  late final Future<List<Playlist>> _future = widget.client.playlists();
  List<Playlist>? _ordered;

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
    return FutureBuilder<List<Playlist>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return ListView(
            children: [
              ErrorView(error: snapshot.error!, onRetry: () => setState(() {})),
            ],
          );
        final loaded = snapshot.data;
        if (loaded == null) return const SongListSkeleton(rows: 6);
        _ordered ??= settings.orderPlaylists(loaded);
        final isFiltering = widget.query.isNotEmpty;
        final shown = [
          for (final p in _ordered!)
            if (_matches(p.name, widget.query)) p,
        ];
        return ListView(
          children: [
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
                  leading: CoverArt(
                    coverArtId: playlist.coverArtId,
                    size: 56,
                    radius: 12,
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
    return AsyncSection<List<Song>>(
      load: () async => (await client.search(query, count: 100)).songs,
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
