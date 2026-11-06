import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/listening/play_history.dart';
import '../../core/messaging/music_to_send.dart';
import '../../core/messaging/send_suggestions.dart';
import '../../core/models.dart';
import '../../state/catalog_controller.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import 'cover_art.dart';

/// How long the search bar takes to open out.
const Duration _barOpening = Duration(milliseconds: 420);

/// How long each row takes to slide in, and the gap before the next one starts.
const Duration _rowIn = Duration(milliseconds: 260);
const int _rowStaggerMs = 28;
const int _maxStaggeredRows = 12;

/// Loads the playlists a picker can offer.
typedef PlaylistLoader = Future<List<Playlist>> Function();

enum _Tab {
  recent('Recent'),
  songs('Songs'),
  albums('Albums'),
  playlists('Playlists'),
  liked('Liked');

  const _Tab(this.label);
  final String label;
}

/// Lets you pick music to send: recent plays are ready, every song, album, playlist and
/// liked song can be browsed, and the search bar looks through all of them.
Future<PickedMusic?> pickMusicToSend(
  BuildContext context, {
  PlaylistLoader? loadPlaylists,
}) {
  final loader =
      loadPlaylists ?? context.read<SessionController>().client.playlists;
  return showModalBottomSheet<PickedMusic>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: YomiColors.surface,
    builder: (_) => _MusicPicker(loadPlaylists: loader),
  );
}

class _MusicPicker extends StatefulWidget {
  const _MusicPicker({required this.loadPlaylists});

  final PlaylistLoader loadPlaylists;

  @override
  State<_MusicPicker> createState() => _MusicPickerState();
}

class _MusicPickerState extends State<_MusicPicker> {
  final _query = TextEditingController();
  _Tab _tab = _Tab.recent;
  List<Playlist> _playlists = const [];
  bool _isLoadingPlaylists = true;
  String? _playlistError;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    try {
      final playlists = await widget.loadPlaylists();
      if (mounted) setState(() => _playlists = List.unmodifiable(playlists));
    } on Exception catch (error) {
      debugPrint('Picker could not load playlists: $error');
      if (mounted) setState(() => _playlistError = "Couldn't load playlists.");
    } finally {
      if (mounted) setState(() => _isLoadingPlaylists = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool get _isSearching => _query.text.trim().isNotEmpty;

  List<PickedMusic> _items(BuildContext context) {
    final catalog = context.read<CatalogController>();
    if (_isSearching) {
      return searchToSend(
        _query.text,
        index: catalog.searchIndex,
        playlists: _playlists,
      );
    }
    return switch (_tab) {
      _Tab.recent => _recent(context),
      _Tab.songs => [for (final song in catalog.songs) PickedSong(song)],
      _Tab.albums => albumsToSend(catalog.songs),
      _Tab.playlists => [for (final p in _playlists) PickedPlaylist(p)],
      _Tab.liked => likedToSend(catalog.songs),
    };
  }

  List<PickedMusic> _recent(BuildContext context) {
    final history = context.read<PlayHistory>();
    return [
      for (final song in recentToSend(
        events: history.events,
        songFor: history.songFor,
        nowPlaying: context.read<PlayerController>().current,
      ))
        PickedSong(song),
    ];
  }

  String get _emptyText {
    if (_isSearching) return 'Nothing matches that.';
    return switch (_tab) {
      _Tab.recent => 'Play something, or search above.',
      _Tab.songs || _Tab.albums => 'Your library is still loading.',
      _Tab.playlists =>
        _isLoadingPlaylists
            ? 'Loading playlists…'
            : _playlistError ?? 'No playlists yet.',
      _Tab.liked => 'Songs you like show up here.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final items = _items(context);
    final playingId = context.read<PlayerController>().current?.id;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: YomiColors.textSecondary.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              16,
              kPagePadding,
              8,
            ),
            child: _OpeningSearchBar(
              controller: _query,
              onChanged: (_) => setState(() {}),
            ),
          ),
          AnimatedSize(
            duration: YomiMotion.standard,
            child: _isSearching
                ? const SizedBox(width: double.infinity)
                : _TabChips(
                    selected: _tab,
                    onSelected: (tab) => setState(() => _tab = tab),
                  ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: YomiMotion.standard,
              child: items.isEmpty
                  ? Center(
                      key: ValueKey('empty|$_tab|$_isSearching'),
                      child: Text(
                        _emptyText,
                        style: yomiText(14, color: YomiColors.textSecondary),
                      ),
                    )
                  : ListView.builder(
                      key: ValueKey('list|$_tab|$_isSearching'),
                      controller: scroll,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: items.length,
                      itemBuilder: (context, i) => _SlidesIn(
                        key: ValueKey('${_query.text}|${items[i].id}'),
                        index: i,
                        child: _MusicRow(
                          item: items[i],
                          isPlaying:
                              _tab == _Tab.recent &&
                              !_isSearching &&
                              i == 0 &&
                              items[i] is PickedSong &&
                              (items[i] as PickedSong).song.id == playingId,
                          onSend: () => Navigator.pop(context, items[i]),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabChips extends StatelessWidget {
  const _TabChips({required this.selected, required this.onSelected});

  final _Tab selected;
  final ValueChanged<_Tab> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
      children: [
        for (final tab in _Tab.values)
          Padding(
            padding: const EdgeInsets.only(right: YomiSpace.s),
            child: ChoiceChip(
              label: Text(tab.label),
              selected: tab == selected,
              onSelected: (_) => onSelected(tab),
            ),
          ),
      ],
    ),
  );
}

/// A search bar that opens out from a small pill when the sheet appears.
class _OpeningSearchBar extends StatelessWidget {
  const _OpeningSearchBar({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: _barOpening,
    curve: Curves.easeOutBack,
    builder: (context, open, child) => Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: 0.3 + 0.7 * open.clamp(0, 1),
        child: Opacity(opacity: open.clamp(0, 1), child: child),
      ),
    ),
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: yomiText(16, weight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: 'Search songs, albums, playlists',
        prefixIcon: Icon(Icons.search_rounded, color: context.accent),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
      ),
    ),
  );
}

/// Fades and slides a row up, each a moment after the one above.
class _SlidesIn extends StatelessWidget {
  const _SlidesIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = min(index, _maxStaggeredRows) * _rowStaggerMs;
    final total = _rowIn.inMilliseconds + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _MusicRow extends StatelessWidget {
  const _MusicRow({
    required this.item,
    required this.isPlaying,
    required this.onSend,
  });

  final PickedMusic item;
  final bool isPlaying;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: kPagePadding),
    leading: CoverArt(
      coverArtId: item.coverArtId,
      size: 48,
      radius: YomiRadius.art,
      seed: item.title,
    ),
    title: Text(
      item.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: yomiText(15, weight: FontWeight.w700),
    ),
    subtitle: Text(
      isPlaying ? 'Playing now · ${item.subtitle}' : item.subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: IconButton(
      tooltip: 'Send ${item.title}',
      icon: Icon(Icons.send_rounded, color: context.accent),
      onPressed: onSend,
    ),
    onTap: onSend,
  );
}
