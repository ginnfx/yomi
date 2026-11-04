import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/genres.dart';
import '../../core/models.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../../state/home_controller.dart';
import '../../core/subsonic_client.dart';
import '../theme.dart';
import '../widgets/album_card.dart';
import '../widgets/async_section.dart';
import '../widgets/cover_art.dart';
import '../widgets/compact_music_grid.dart';
import '../widgets/error_view.dart';
import '../widgets/genre_filter_bar.dart';
import '../widgets/shimmer.dart';
import '../widgets/song_tile.dart';
import 'collection_page.dart';

const Duration _debounce = Duration(milliseconds: 300);
const double _avatarSize = 88;
const int _pageSize = 40;

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  Timer? _timer;
  List<Artist> _artists = const [];
  List<Song> _songs = const [];
  Set<String> _selectedGenres = const {};
  bool _hasSearched = false;
  bool _hasMore = false;
  Object? _error;
  bool _isLoading = false;
  int _generation = 0;
  int _browseRevision = 0;
  String? _routeUrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final url = context.watch<SessionController>().serverUrl;
    if (_routeUrl != null && _routeUrl != url) {
      _generation++;
      _error = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.text.trim().isNotEmpty)
          _search(_controller.text);
      });
    }
    _routeUrl = url;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _generation++;
    _timer?.cancel();
    setState(() {});
    if (text.trim().isEmpty) {
      setState(() {
        _hasSearched = false;
        _artists = const [];
        _songs = const [];
        _selectedGenres = const {};
        _error = null;
        _isLoading = false;
      });
      return;
    }
    _timer = Timer(_debounce, () => _search(text));
  }

  Future<void> _search(String text, {bool more = false}) async {
    final generation = ++_generation;
    setState(() => _isLoading = true);
    final session = context.read<SessionController>();
    final local =
        <String, Song>{
              for (final shelf in context.read<HomeController>().shelves)
                for (final song in shelf.songs) song.id: song,
            }.values
            .where(
              (song) => '${song.title} ${song.artist} ${song.album}'
                  .toLowerCase()
                  .contains(text.trim().toLowerCase()),
            )
            .toList();
    if (!more && local.isNotEmpty) {
      setState(() {
        _songs = local;
        _artists = const [];
        _hasSearched = true;
        _error = null;
      });
    }
    try {
      SearchResults results;
      try {
        results = await session.client.search(
          text,
          count: _pageSize,
          offset: more ? _songs.length : 0,
        );
      } on SubsonicException catch (error) {
        if (error.kind != ErrorKind.unreachable) rethrow;
        await session.checkServer();
        results = await session.client.search(
          text,
          count: _pageSize,
          offset: more ? _songs.length : 0,
        );
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        if (more) {
          _songs = [..._songs, ...results.songs];
        } else {
          _artists = results.artists;
          _songs = results.songs;
        }
        _hasSearched = true;
        _hasMore = results.songs.length == _pageSize;
        _error = null;
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = _songs.isEmpty ? error : null;
        _isLoading = false;
      });
    }
  }

  /// Genres present in the current results, so a chip can never lead to nothing.
  List<GenreGroup> get _resultGenres {
    final counts = <String, int>{};
    for (final genre in _songs.map((song) => song.genre).whereType<String>()) {
      counts[genre] = (counts[genre] ?? 0) + 1;
    }
    return groupGenres([
      for (final entry in counts.entries) Genre(entry.key, entry.value),
    ]);
  }

  List<Song> get _visibleSongs => [
    for (final song in _songs)
      if (songMatchesGenres(song, _selectedGenres)) song,
  ];

  @override
  Widget build(BuildContext context) {
    final client = context.watch<SessionController>().client;
    final player = context.read<PlayerController>();
    final isEmpty = _hasSearched && _artists.isEmpty && _songs.isEmpty;
    return SafeArea(
      bottom: false,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              22,
              kPagePadding,
              16,
            ),
            child: Text(
              'Search',
              style: yomiText(36, weight: FontWeight.w800, letterSpacing: -1),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            child: TextField(
              controller: _controller,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              style: yomiText(16, weight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: 'Songs and artists',
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: YomiColors.textSecondary,
                ),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _controller.clear();
                          _onChanged('');
                        },
                      ),
              ),
            ),
          ),
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: context.accent,
                backgroundColor: Colors.transparent,
              ),
            ),
          if (_error != null)
            ErrorView(error: _error!, onRetry: () => _search(_controller.text))
          else if (!_hasSearched) ...[
            Row(
              children: [
                const Expanded(child: SectionTitle('Browse')),
                IconButton(
                  tooltip: 'Refresh suggestions',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () => setState(() => _browseRevision++),
                ),
                const SizedBox(width: kPagePadding),
              ],
            ),
            AsyncSection<List<Song>>(
              skeleton: const Padding(
                padding: EdgeInsets.symmetric(horizontal: kPagePadding),
                child: Shimmer(child: SkeletonBox(height: 200, radius: 16)),
              ),
              key: ValueKey('browse-$_browseRevision'),
              load: () {
                final songs = <String, Song>{
                  for (final shelf in context.read<HomeController>().shelves)
                    for (final song in shelf.songs) song.id: song,
                }.values.toList()..shuffle();
                return songs.isEmpty
                    ? client
                          .randomSongs(size: 24)
                          .then(
                            (pool) =>
                                (pool.toList()..shuffle()).take(8).toList(),
                          )
                    : Future.value(songs.take(8).toList());
              },
              builder: (context, songs) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
                child: context.isWideLayout
                    ? CompactMusicGrid(
                        items: [
                          for (var i = 0; i < songs.length; i++)
                            MusicShortcut(
                              title: songs[i].title,
                              subtitle: songs[i].artist,
                              coverArtId: songs[i].coverArtId,
                              onTap: () =>
                                  player.playQueue(songs, startIndex: i),
                            ),
                        ],
                      )
                    : GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.45,
                        children: [
                          for (var i = 0; i < songs.length; i++)
                            _BrowseTile(
                              song: songs[i],
                              onTap: () =>
                                  player.playQueue(songs, startIndex: i),
                            ),
                        ],
                      ),
              ),
            ),
          ] else if (isEmpty)
            Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                children: [
                  const Icon(
                    Icons.search_off_rounded,
                    size: 44,
                    color: YomiColors.textSecondary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Nothing for "${_controller.text.trim()}"',
                    textAlign: TextAlign.center,
                    style: yomiText(16, weight: FontWeight.w700),
                  ),
                ],
              ),
            )
          else ...[
            if (_artists.isNotEmpty) ...[
              const SectionTitle('Artists'),
              SizedBox(
                height: _avatarSize + 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
                  itemCount: _artists.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 18),
                  itemBuilder: (context, i) {
                    final artist = _artists[i];
                    return GestureDetector(
                      onTap: () => openArtist(context, artist),
                      child: SizedBox(
                        width: _avatarSize,
                        child: Column(
                          children: [
                            ArtistAvatar(
                              artistId: artist.id,
                              name: artist.name,
                              size: _avatarSize,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              artist.name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: yomiText(
                                13,
                                weight: FontWeight.w700,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            if (_songs.isNotEmpty) ...[
              SectionTitle(
                'Songs',
                trailing: Text(
                  '${_songs.length}${_hasMore ? '+' : ''}',
                  style: yomiText(
                    13,
                    weight: FontWeight.w700,
                    color: YomiColors.textSecondary,
                  ),
                ),
              ),
              GenreFilterBar(
                groups: _resultGenres,
                selected: _selectedGenres,
                onChanged: (selected) =>
                    setState(() => _selectedGenres = selected),
              ),
              for (var i = 0; i < _visibleSongs.length; i++)
                SongTile(
                  song: _visibleSongs[i],
                  onTap: () => player.playQueue(_visibleSongs, startIndex: i),
                ),
              if (_hasMore)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: OutlinedButton(
                      onPressed: _isLoading
                          ? null
                          : () => _search(_controller.text, more: true),
                      child: const Text('Show more songs'),
                    ),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

class _BrowseTile extends StatelessWidget {
  const _BrowseTile({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          LayoutBuilder(
            builder: (context, c) => CoverArt(
              coverArtId: song.coverArtId,
              size: c.maxWidth,
              radius: 18,
              seed: song.title,
              artist: song.artist,
              album: song.album,
              title: song.title,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.78),
                ],
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(14, weight: FontWeight.w800, height: 1.15),
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(
                    12,
                    weight: FontWeight.w500,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
