import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ai/ai_api.dart';
import '../../core/mixes.dart';
import '../../core/taste.dart';
import '../../state/ai_controller.dart';
import '../../state/catalog_controller.dart';
import '../../state/home_controller.dart';
import '../pages/playlist_preview_page.dart';
import '../theme.dart';
import 'album_card.dart';
import 'mosaic_cover.dart';

/// "Made for you": mixes from your favourite moods, named by DeepSeek.
class MadeForYou extends StatefulWidget {
  const MadeForYou({super.key});

  @override
  State<MadeForYou> createState() => _MadeForYouState();
}

class _MadeForYouState extends State<MadeForYou> {
  List<SuggestedMix> _mixes = const [];
  Map<String, MixName> _names = const {};
  TasteProfile? _builtFor;
  int _builtForSongs = -1;
  int _builtForLabels = -1;
  final _random = Random();

  void _rebuildIfNeeded() {
    final taste = context.watch<HomeController>().taste;
    final catalog = context.watch<CatalogController>();
    final ai = context.watch<AiController>();
    final labels = ai.labelledCount;
    if (identical(taste, _builtFor) &&
        catalog.songs.length == _builtForSongs &&
        labels == _builtForLabels) {
      return;
    }
    _builtFor = taste;
    _builtForSongs = catalog.songs.length;
    _builtForLabels = labels;
    _mixes = suggestMixes(
      library: catalog.songs,
      taste: taste,
      tagFor: ai.tagFor,
      random: _random,
    );
    final requests = [for (final mix in _mixes) mix.request];
    if (requests.isEmpty) return;
    ai.nameMixes(requests).then((names) {
      if (mounted) setState(() => _names = names);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: context.motion(YomiMotion.standard),
    curve: YomiMotion.curve,
    alignment: Alignment.topCenter,
    child: _content(context),
  );

  Widget _content(BuildContext context) {
    _rebuildIfNeeded();
    if (_mixes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Made for you'),
        CardRow(
          children: [
            for (final mix in _mixes)
              AlbumCard(
                title: _names[mix.request.key]?.name ?? mix.plainName,
                subtitle: mix.artists.isEmpty
                    ? '${mix.songs.length} songs'
                    : mix.artists.join(', '),
                coverArtId: null,
                cover: MosaicCover(
                  songs: mix.songs,
                  size: kCardWidth,
                  radius: kCardRadius,
                  seed: mix.plainName,
                ),
                onTap: () => openPlaylistPreview(
                  context,
                  name: _names[mix.request.key]?.name ?? mix.plainName,
                  description: _names[mix.request.key]?.description ?? '',
                  songs: mix.songs,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
