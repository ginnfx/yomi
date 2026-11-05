import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/spotify/missing_songs.dart';
import '../../state/imports_controller.dart';
import '../imports/imported_playlist_page.dart';
import '../theme.dart';

/// How many to show before "Show all".
const int _shownAtFirst = 5;

/// Songs your imported playlists have that the library doesn't yet, as things to add.
class MissingSongsSection extends StatefulWidget {
  const MissingSongsSection({super.key});

  @override
  State<MissingSongsSection> createState() => _MissingSongsSectionState();
}

class _MissingSongsSectionState extends State<MissingSongsSection> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final missing = missingFromImports(
      context.watch<ImportsController>().playlists,
    );
    if (missing.isEmpty) return const SizedBox.shrink();
    final shown = _showAll ? missing : missing.take(_shownAtFirst).toList();
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
          child: Text('To add', style: yomiText(16, weight: FontWeight.w800)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 4),
          child: Text(
            '${missing.length} songs from your imported playlists aren\'t in '
            'your library yet. Add them and they fill their places.',
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
              '${song.artist} · From ${song.playlists.join(', ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: 'Find on YouTube',
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: () => launchUrl(
                youtubeSearchFor(song.artist, song.title),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ),
        if (missing.length > _shownAtFirst)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding - 8),
            child: TextButton(
              onPressed: () => setState(() => _showAll = !_showAll),
              child: Text(
                _showAll ? 'Show fewer' : 'Show all ${missing.length}',
              ),
            ),
          ),
      ],
    );
  }
}
