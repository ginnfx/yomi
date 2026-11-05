import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/listening/play_history.dart';
import '../../core/messaging/send_suggestions.dart';
import '../../core/models.dart';
import '../../state/catalog_controller.dart';
import '../../state/player_controller.dart';
import '../theme.dart';
import 'cover_art.dart';

/// How many search results to offer.
const int _maxResults = 40;

/// How long the search bar takes to open out.
const Duration _barOpening = Duration(milliseconds: 420);

/// How long each row takes to slide in, and the gap before the next one starts.
const Duration _rowIn = Duration(milliseconds: 260);
const int _rowStaggerMs = 28;
const int _maxStaggeredRows = 12;

/// Lets you pick a song to send: what you played lately is ready, or search the library.
Future<Song?> pickSongToSend(BuildContext context) =>
    showModalBottomSheet<Song>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: YomiColors.surface,
      builder: (_) => const _SongPicker(),
    );

class _SongPicker extends StatefulWidget {
  const _SongPicker();

  @override
  State<_SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends State<_SongPicker> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<Song> _songs(BuildContext context) {
    final text = _query.text.trim();
    if (text.isNotEmpty) {
      return context
          .read<CatalogController>()
          .searchIndex
          .search(text)
          .songs
          .take(_maxResults)
          .toList();
    }
    final history = context.read<PlayHistory>();
    return recentToSend(
      events: history.events,
      songFor: history.songFor,
      nowPlaying: context.read<PlayerController>().current,
    );
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs(context);
    final isSearching = _query.text.trim().isNotEmpty;
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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              8,
              kPagePadding,
              4,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                isSearching ? 'Results' : 'Recently played',
                style: yomiText(14, weight: FontWeight.w800),
              ),
            ),
          ),
          Expanded(
            child: songs.isEmpty
                ? Center(
                    child: Text(
                      isSearching
                          ? 'Nothing matches that.'
                          : 'Play something, or search above.',
                      style: yomiText(14, color: YomiColors.textSecondary),
                    ),
                  )
                : ListView.builder(
                    controller: scroll,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: songs.length,
                    itemBuilder: (context, i) => _SlidesIn(
                      key: ValueKey('${_query.text}|${songs[i].id}'),
                      index: i,
                      child: _SongRow(
                        song: songs[i],
                        isPlaying:
                            !isSearching &&
                            i == 0 &&
                            context.read<PlayerController>().current?.id ==
                                songs[i].id,
                        onSend: () => Navigator.pop(context, songs[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
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
        hintText: 'Search songs to send',
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

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.song,
    required this.isPlaying,
    required this.onSend,
  });

  final Song song;
  final bool isPlaying;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => ListTile(
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
    subtitle: Text(
      isPlaying ? 'Playing now · ${song.artist}' : song.artist,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: IconButton(
      tooltip: 'Send ${song.title}',
      icon: Icon(Icons.send_rounded, color: context.accent),
      onPressed: onSend,
    ),
    onTap: onSend,
  );
}
