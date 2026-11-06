import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/genres.dart';
import '../../core/models.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../../core/ai/ai_api.dart';
import '../../core/ai/vibe_words.dart';
import '../../core/search_index.dart';
import '../../core/taste.dart';
import '../../state/ai_controller.dart';
import '../../state/catalog_controller.dart';
import '../../state/home_controller.dart';
import '../../state/settings.dart';
import '../../core/subsonic_client.dart';
import '../assistant/ask_yomi_button.dart';
import '../theme.dart';
import '../widgets/album_card.dart';
import '../widgets/async_section.dart';
import '../widgets/cover_art.dart';
import '../widgets/compact_music_grid.dart';
import '../widgets/error_view.dart';
import '../widgets/genre_filter_bar.dart';
import '../widgets/shimmer.dart';
import '../widgets/local_results.dart';
import '../widgets/search_sections.dart';
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

/// A search this many words long may be a description rather than a name.
const int _minWordsForDescription = 3;

/// With this few matches, a description is more likely than a title.
const int _fewResults = 3;
const Duration _describeDebounce = Duration(milliseconds: 700);
const int _maxDescribedSongs = 100;

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();

  /// Recent searches show only while the search bar is tapped into.
  late final FocusNode _searchFocus = FocusNode()
    ..addListener(() => setState(() {}));
  Timer? _timer;
  List<Artist> _artists = const [];
  List<Song> _songs = const [];
  Set<String> _selectedGenres = const {};
  bool _hasSearched = false;
  IndexedResults? _indexed;
  SearchFilters? _filters;

  /// Songs that fit the mood or description, shown beside title matches.
  List<Song> _vibeSongs = const [];
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
    // Results stay on screen after a route change. Only a search that failed runs again.
    if (_routeUrl != null && _routeUrl != url && _error != null) {
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
    _searchFocus.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _generation++;
    _timer?.cancel();
    setState(() {});
    if (text.trim().isEmpty) {
      setState(() {
        _hasSearched = false;
        _indexed = null;
        _filters = null;
        _vibeSongs = const [];
        _artists = const [];
        _songs = const [];
        _selectedGenres = const {};
        _error = null;
        _isLoading = false;
      });
      return;
    }
    final catalog = context.read<CatalogController>();
    if (catalog.isLoaded) {
      _searchLibrary(catalog, text);
      return;
    }
    _timer = Timer(_debounce, () => _search(text));
  }

  /// Instant, offline, and without results moving once they appear.
  void _searchLibrary(CatalogController catalog, String text) {
    final results = catalog.searchIndex.search(text);
    setState(() {
      _filters = null;
      _vibeSongs = const [];
      _indexed = results;
      _artists = const [];
      _songs = results.songs;
      _selectedGenres = const {};
      _hasSearched = true;
      _hasMore = false;
      _error = null;
      _isLoading = false;
    });
    // Mood words like "happy" or "chill songs" need no AI call.
    if (filtersForWords(text) case final vibe?) {
      _applyFilters(catalog, vibe);
      return;
    }
    // A description rather than a name, so ask what it means.
    final wordCount = text.trim().split(RegExp(r'\s+')).length;
    final isDescription =
        wordCount >= _minWordsForDescription ||
        (wordCount > 1 && results.songs.length < _fewResults);
    if (isDescription && context.read<AiController>().isAvailable) {
      _timer = Timer(_describeDebounce, () => _interpret(catalog, text));
    }
  }

  Future<void> _interpret(CatalogController catalog, String text) async {
    final generation = _generation;
    setState(() => _isLoading = true);
    final filters = await context.read<AiController>().interpret(text.trim());
    if (!mounted || generation != _generation) return;
    setState(() => _isLoading = false);
    if (filters != null) _applyFilters(catalog, filters);
  }

  void _applyFilters(CatalogController catalog, SearchFilters filters) {
    final ai = context.read<AiController>();
    // Your own favourites first, so the same words find different songs for each person.
    final taste = context.read<HomeController>().taste;
    setState(() {
      _filters = filters;
      _vibeSongs = filters.isEmpty
          ? const []
          : orderByTaste(
              [
                for (final song in catalog.songs)
                  if (filters.matches(song, ai.tagFor(song))) song,
              ],
              taste,
              Random(),
              take: _maxDescribedSongs,
            );
    });
  }

  void _rememberSearch() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      unawaited(context.read<SettingsController>().addRecentSearch(text));
    }
  }

  void _useRecent(String text) {
    _controller.text = text;
    _onChanged(text);
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
          // Songs already showing stay where they are, so a result can't change just as
          // someone taps it. The server's extra results are added below.
          final showing = {for (final song in _songs) song.id};
          final isRefinement = _songs.isNotEmpty && local.isNotEmpty;
          _songs = isRefinement
              ? [
                  ..._songs,
                  ...results.songs.where((song) => !showing.contains(song.id)),
                ]
              : results.songs;
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

  void _openAll(String title, List<Song> songs) {
    _rememberSearch();
    Navigator.of(context).push(
      yomiRoute<void>(
        builder: (_) => CollectionPage(
          title: title,
          subtitle: '${songs.length} songs',
          savedSongs: songs,
          loadSongs: () async => songs,
        ),
      ),
    );
  }

  /// Mood words lead with the mood; a name leads with what matched it.
  bool get _isVibeFirst =>
      filtersForWords(_controller.text) != null ||
      (_indexed?.songs.length ?? 0) < _fewResults;

  Widget _vibeSection(PlayerController player) {
    final filters = _filters!;
    final text = _controller.text.trim();
    final heading = filtersForWords(text) != null
        ? vibeHeading(filters)
        : 'Fits "$text"';
    return VibeSection(
      heading: heading,
      filters: filters,
      songs: _vibeSongs,
      onFiltersChanged: (next) =>
          _applyFilters(context.read<CatalogController>(), next),
      onPlay: (i) {
        _rememberSearch();
        player.playQueue(_vibeSongs, startIndex: i);
      },
      onSeeAll: () => _openAll(heading, _vibeSongs),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = context.watch<SessionController>().client;
    final player = context.read<PlayerController>();
    final visible = _visibleSongs;
    final indexed = _indexed;
    final isEmpty =
        _hasSearched &&
        _artists.isEmpty &&
        _songs.isEmpty &&
        _filters == null &&
        (indexed == null || indexed.isEmpty);
    // Library results show a few songs and open the rest full screen; server results page.
    final shownSongs = indexed != null && visible.length > kPreviewSongs
        ? visible.take(kPreviewSongs).toList()
        : visible;
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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Search',
                    style: yomiText(
                      36,
                      weight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
                  ),
                ),
                const AskYomiButton(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            child: TextField(
              controller: _controller,
              focusNode: _searchFocus,
              onChanged: _onChanged,
              onSubmitted: (_) => _rememberSearch(),
              textInputAction: TextInputAction.search,
              style: yomiText(16, weight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: 'Songs, artists and albums',
                prefixIcon: Icon(
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
          AnimatedSwitcher(
            duration: context.motion(YomiMotion.quick),
            child: _isLoading
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: context.accent,
                      backgroundColor: Colors.transparent,
                    ),
                  )
                : const SizedBox(width: double.infinity, height: 14),
          ),
          if (_error != null)
            ErrorView(error: _error!, onRetry: () => _search(_controller.text))
          else if (!_hasSearched) ...[
            // Counts as part of the search bar, so tapping a chip doesn't close it first.
            if (_searchFocus.hasFocus)
              TextFieldTapRegion(
                child: _RecentSearches(onSelected: _useRecent),
              ),
            if (context.watch<AiController>().isAvailable)
              MoodChips(onSelected: _useRecent),
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
                  Icon(
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
            if (_filters != null && _isVibeFirst) _vibeSection(player),
            if (indexed != null)
              LocalResults(results: indexed, onOpened: _rememberSearch),
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
                trailing: shownSongs.length < visible.length
                    ? SeeAllButton(
                        count: visible.length,
                        onPressed: () =>
                            _openAll('"${_controller.text.trim()}"', visible),
                      )
                    : Text(
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
              for (var i = 0; i < shownSongs.length; i++)
                SongTile(
                  key: ValueKey(visible[i].id),
                  song: visible[i],
                  onTap: () {
                    _rememberSearch();
                    player.playQueue(visible, startIndex: i);
                  },
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
            if (_filters != null && !_isVibeFirst) _vibeSection(player),
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

/// The groups only local search can offer: the best match, then artists and albums.
/// What you searched for lately, shown before you type.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final recent = settings.recentSearches;
    if (recent.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 12, kPagePadding, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final text in recent)
            ActionChip(label: Text(text), onPressed: () => onSelected(text)),
          ActionChip(
            avatar: const Icon(Icons.close_rounded, size: 16),
            label: const Text('Clear'),
            onPressed: settings.clearRecentSearches,
          ),
        ],
      ),
    );
  }
}
