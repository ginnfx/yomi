import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/search_index.dart';
import '../../core/taste.dart';
import '../../state/catalog_controller.dart';
import '../../state/home_controller.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'error_view.dart';

/// How many suggestions the sheet lists before anything is typed.
const int kAddSheetSuggestions = 100;

/// How much of the screen the sheet covers. Not all of it, so the page behind still
/// peeks out and tapping there closes it.
const double _sheetHeightFactor = 0.96;

/// Opens the "Add songs" sheet for a playlist: a search bar over a long list of songs
/// picked to suit this person, each with a one-tap add. Close it with the X, by pulling it
/// down, or by tapping the page behind.
Future<void> showAddSongsSheet(
  BuildContext context, {
  required String playlistName,
  required List<Song> playlistSongs,
  required Future<void> Function(Song song) onAdd,
}) {
  final catalog = context.read<CatalogController>();
  final taste = context.read<HomeController>().taste;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: YomiColors.surface,
    builder: (_) => FractionallySizedBox(
      heightFactor: _sheetHeightFactor,
      child: AddSongsSheet(
        playlistName: playlistName,
        library: catalog.songs,
        searchIndex: catalog.searchIndex,
        taste: taste,
        alreadyIn: {for (final song in playlistSongs) song.id},
        onAdd: onAdd,
      ),
    ),
  );
}

class AddSongsSheet extends StatefulWidget {
  const AddSongsSheet({
    super.key,
    required this.playlistName,
    required this.library,
    required this.searchIndex,
    required this.taste,
    required this.alreadyIn,
    required this.onAdd,
    this.random,
    this.suggestionCount = kAddSheetSuggestions,
  });

  final String playlistName;
  final List<Song> library;
  final SearchIndex searchIndex;
  final TasteProfile taste;

  /// IDs of songs the playlist already has. They are never offered.
  final Set<String> alreadyIn;

  /// Puts a song in the playlist. Throws if it couldn't.
  final Future<void> Function(Song song) onAdd;
  final Random? random;
  final int suggestionCount;

  @override
  State<AddSongsSheet> createState() => _AddSongsSheetState();
}

class _AddSongsSheetState extends State<AddSongsSheet> {
  final _query = TextEditingController();
  final Set<String> _added = {};
  final Set<String> _adding = {};
  late final List<Song> _suggested;

  @override
  void initState() {
    super.initState();
    _suggested = orderByTaste(
      [
        for (final song in widget.library)
          if (!widget.alreadyIn.contains(song.id)) song,
      ],
      widget.taste,
      widget.random ?? Random(),
      take: widget.suggestionCount,
    );
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool get _isSearching => _query.text.trim().isNotEmpty;

  List<Song> get _shown => _isSearching
      ? [
          for (final song in widget.searchIndex.search(_query.text).songs)
            if (!widget.alreadyIn.contains(song.id)) song,
        ]
      : _suggested;

  Future<void> _add(Song song) async {
    if (_adding.contains(song.id) || _added.contains(song.id)) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding.add(song.id));
    try {
      await widget.onAdd(song);
      if (mounted) setState(() => _added.add(song.id));
    } on Exception catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeFailure(context, error).title)),
      );
    } finally {
      if (mounted) setState(() => _adding.remove(song.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final songs = _shown;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 0, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Add to ${widget.playlistName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(
                    20,
                    weight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search songs, artists, albums',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _isSearching
                  ? IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(_query.clear),
                    )
                  : null,
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(YomiRadius.art),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 14, kPagePadding, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _isSearching ? 'Results' : 'Suggested for you',
              style: yomiText(14, color: YomiColors.textSecondary),
            ),
          ),
        ),
        Expanded(
          child: songs.isEmpty
              ? Center(
                  child: Text(
                    _isSearching
                        ? 'Nothing matches that.'
                        : 'Your library is still loading.',
                    style: yomiText(14, color: YomiColors.textSecondary),
                  ),
                )
              : ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: songs.length,
                  itemBuilder: (context, index) => _row(songs[index]),
                ),
        ),
      ],
    );
  }

  Widget _row(Song song) {
    final isAdded = _added.contains(song.id);
    return ListTile(
      key: ValueKey('add-${song.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: kPagePadding),
      leading: CoverArt(
        coverArtId: song.coverArtId,
        size: 48,
        radius: YomiRadius.art,
        seed: song.album,
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: yomiText(15, weight: FontWeight.w700),
      ),
      subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: isAdded ? 'Added' : 'Add',
        iconSize: 30,
        color: isAdded ? context.accent : null,
        icon: Icon(
          isAdded ? Icons.check_circle_rounded : Icons.add_circle_outline,
        ),
        onPressed: _adding.contains(song.id) || isAdded
            ? null
            : () => _add(song),
      ),
    );
  }
}

/// The "+ Add" pill under a playlist's buttons, which opens the song picker.
class AddChip extends StatelessWidget {
  const AddChip({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white.withValues(alpha: 0.12),
    shape: const StadiumBorder(),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add_rounded, size: 22),
            const SizedBox(width: 8),
            Text('Add', style: yomiText(15, weight: FontWeight.w700)),
          ],
        ),
      ),
    ),
  );
}
