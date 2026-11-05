import 'package:flutter/material.dart';

import 'dart:math';

import '../../core/ai/ai_api.dart';
import '../../core/ai/vibe_words.dart';
import '../../core/models.dart';
import '../theme.dart';
import 'album_card.dart';
import 'song_tile.dart';

/// Songs shown in a section before "See all" opens the full list.
const int kPreviewSongs = 8;

/// "See all 42", for a section with more than it shows.
class SeeAllButton extends StatelessWidget {
  const SeeAllButton({required this.count, required this.onPressed, super.key});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: onPressed, child: Text('See all $count'));
}

/// Songs that fit a mood or description, with what it was understood to mean.
class VibeSection extends StatelessWidget {
  const VibeSection({
    required this.heading,
    required this.filters,
    required this.songs,
    required this.onFiltersChanged,
    required this.onPlay,
    required this.onSeeAll,
    super.key,
  });

  final String heading;
  final SearchFilters filters;
  final List<Song> songs;
  final ValueChanged<SearchFilters> onFiltersChanged;
  final ValueChanged<int> onPlay;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final shown = min(songs.length, kPreviewSongs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          heading,
          trailing: songs.length > shown
              ? SeeAllButton(count: songs.length, onPressed: onSeeAll)
              : null,
        ),
        FilterChips(filters: filters, onChanged: onFiltersChanged),
        if (songs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              12,
              kPagePadding,
              8,
            ),
            child: Text(
              'Nothing fits yet. Yomi is still learning the mood of your '
              'songs, so more will turn up soon.',
              style: yomiText(14, color: YomiColors.textSecondary),
            ),
          ),
        for (var i = 0; i < shown; i++)
          SongTile(
            key: ValueKey('vibe-${songs[i].id}'),
            song: songs[i],
            onTap: () => onPlay(i),
          ),
      ],
    );
  }
}

/// One tap to songs of a mood, before anything is typed.
class MoodChips extends StatelessWidget {
  const MoodChips({required this.onSelected, super.key});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionTitle('Moods'),
      SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
          itemCount: kVibeChips.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final mood = kVibeChips[i];
            return ActionChip(
              label: Text('${mood[0].toUpperCase()}${mood.substring(1)}'),
              onPressed: () => onSelected(mood),
            );
          },
        ),
      ),
    ],
  );
}

/// What a description was understood to mean, each part removable.
class FilterChips extends StatelessWidget {
  const FilterChips({required this.filters, required this.onChanged});

  final SearchFilters filters;
  final ValueChanged<SearchFilters> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, SearchFilters next) =>
        InputChip(label: Text(label), onDeleted: () => onChanged(next));
    final energy = filters.energy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 12, kPagePadding, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final mood in filters.moods)
            chip(mood, filters.without(mood: mood)),
          if (energy != null)
            chip('$energy energy', filters.without(energy: true)),
          for (final genre in filters.genres)
            chip(genre, filters.without(genre: genre)),
          for (final artist in filters.artists)
            chip(artist, filters.without(artist: artist)),
          for (final mood in filters.excludeMoods)
            chip('not $mood', filters.without(excludeMood: mood)),
        ],
      ),
    );
  }
}
