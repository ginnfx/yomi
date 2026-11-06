import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/reports_controller.dart';
import '../theme.dart';
import 'youtube_play_button.dart';

/// How many to show before "Show all".
const int _shownAtFirst = 5;

/// Every song anyone has asked for that the library doesn't have, most wanted first. It
/// says how many people want each one, but never who.
class WantedSongsSection extends StatefulWidget {
  const WantedSongsSection({super.key});

  @override
  State<WantedSongsSection> createState() => _WantedSongsSectionState();
}

class _WantedSongsSectionState extends State<WantedSongsSection> {
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    // After the first frame, so it never changes what's showing mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ReportsController>().refreshWanted();
    });
  }

  @override
  Widget build(BuildContext context) {
    final wanted = context.watch<ReportsController>().wanted;
    if (wanted.isEmpty) return const SizedBox.shrink();
    final shown = _showAll ? wanted : wanted.take(_shownAtFirst).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kPagePadding,
            YomiSpace.xl,
            kPagePadding,
            2,
          ),
          child: Text(
            'Wanted by everyone',
            style: yomiText(16, weight: FontWeight.w800),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 4),
          child: Text(
            '${wanted.length} songs people have asked for that aren\'t in the '
            'library yet. Upload one and it drops off this list.',
            style: yomiText(13, color: YomiColors.textSecondary),
          ),
        ),
        for (final song in shown)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: kPagePadding,
            ),
            leading: const Icon(Icons.music_note_rounded),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(15, weight: FontWeight.w700),
            ),
            subtitle: Text(
              song.count > 1
                  ? '${song.artist} · ${song.count} people want this'
                  : song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: YoutubePlayButton(artist: song.artist, title: song.title),
          ),
        if (wanted.length > _shownAtFirst)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding - 8),
            child: TextButton(
              onPressed: () => setState(() => _showAll = !_showAll),
              child: Text(
                _showAll ? 'Show fewer' : 'Show all ${wanted.length}',
              ),
            ),
          ),
      ],
    );
  }
}
