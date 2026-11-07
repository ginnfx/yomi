import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/mixes.dart';
import '../../core/taste.dart';
import '../../core/models.dart';
import '../../state/ai_controller.dart';
import '../../state/catalog_controller.dart';
import '../../state/home_controller.dart';
import '../../state/player_controller.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'error_view.dart';

/// How many songs to recommend at a time.
const int _recommendedCount = 10;

/// "Recommended, based on what's in this playlist", each with an Add button, like Spotify.
class PlaylistRecommendations extends StatefulWidget {
  const PlaylistRecommendations({
    super.key,
    required this.songs,
    required this.onAdd,
  });

  final List<Song> songs;

  /// Puts a song in the playlist. Throws if it couldn't.
  final Future<void> Function(Song song) onAdd;

  @override
  State<PlaylistRecommendations> createState() =>
      _PlaylistRecommendationsState();
}

class _PlaylistRecommendationsState extends State<PlaylistRecommendations> {
  final _random = Random();
  final Set<String> _passedOver = {};
  final Set<String> _adding = {};
  List<Song>? _picks;

  List<Song> _pick() {
    final ai = context.read<AiController>();
    final skip = {for (final song in widget.songs) song.id, ..._passedOver};
    final library = [
      for (final song in context.read<CatalogController>().songs)
        if (!skip.contains(song.id)) song,
    ];
    final taste = context.read<HomeController>().taste;
    // An empty playlist has nothing to go on, so start from what you like.
    if (widget.songs.isEmpty) {
      return orderByTaste(library, taste, _random, take: _recommendedCount);
    }
    return similarToAdd(
      playlist: widget.songs,
      library: library,
      taste: taste,
      tagFor: ai.tagFor,
      similarArtists: ai.similarArtists,
      random: _random,
      count: _recommendedCount,
    );
  }

  void _refresh() => setState(() {
    _passedOver.addAll([for (final song in _picks ?? const <Song>[]) song.id]);
    _picks = _pick();
  });

  Future<void> _add(Song song) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding.add(song.id));
    try {
      await widget.onAdd(song);
      if (!mounted) return;
      setState(() {
        _picks = [
          for (final pick in _picks ?? const <Song>[])
            if (pick.id != song.id) pick,
        ];
      });
    } on Exception catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(failureMessage(context, error))),
      );
    } finally {
      if (mounted) setState(() => _adding.remove(song.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final picks = _picks ??= _pick();
    if (picks.isEmpty && _passedOver.isEmpty) return const SizedBox.shrink();
    final player = context.read<PlayerController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 28, kPagePadding, 2),
          child: Text(
            'Recommended',
            style: yomiText(20, weight: FontWeight.w800, letterSpacing: -0.3),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 8),
          child: Text(
            widget.songs.isEmpty
                ? 'Based on what you play'
                : "Based on what's in this playlist",
            style: yomiText(13, color: YomiColors.textSecondary),
          ),
        ),
        for (final song in picks)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: kPagePadding,
            ),
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
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: OutlinedButton(
              onPressed: _adding.contains(song.id) ? null : () => _add(song),
              style: OutlinedButton.styleFrom(
                shape: const StadiumBorder(),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Add'),
            ),
            onTap: () => player.playQueue([song]),
          ),
        if (picks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            child: Text(
              "That's everything that fits for now.",
              style: yomiText(14, color: YomiColors.textSecondary),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: kPagePadding - 8),
            child: TextButton(
              onPressed: _refresh,
              child: const Text('Refresh'),
            ),
          ),
        ),
      ],
    );
  }
}
