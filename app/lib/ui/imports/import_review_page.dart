import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/spotify/imported_playlist.dart';
import '../../core/spotify/spotify_export.dart';
import '../../core/spotify/track_matcher.dart';
import '../../state/catalog_controller.dart';
import '../../state/imports_controller.dart';
import '../theme.dart';
import 'imported_playlist_page.dart';

/// Shows how each track matched, so nothing wrong gets saved unnoticed.
class ImportReviewPage extends StatefulWidget {
  const ImportReviewPage({
    super.key,
    required this.playlist,
    this.mayBeIncomplete = false,
  });

  final ExportPlaylist playlist;

  /// The source may have cut the list short, which has to be said out loud.
  final bool mayBeIncomplete;

  @override
  State<ImportReviewPage> createState() => _ImportReviewPageState();
}

class _ImportReviewPageState extends State<ImportReviewPage> {
  late final List<ReviewedTrack> _tracks = reviewTracks(
    widget.playlist.tracks,
    context.read<CatalogController>().songs,
  );

  /// Your choices, by position. Null means "leave this place empty".
  final Map<int, Song?> _choices = {};
  bool _isSaving = false;

  Song? _songAt(int i) =>
      _choices.containsKey(i) ? _choices[i] : _tracks[i].match.song;

  Future<void> _choose(int i) async {
    final track = _tracks[i];
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final song in track.match.alternatives)
              ListTile(
                title: Text(song.title),
                subtitle: Text('${song.artist} · ${song.album}'),
                onTap: () => Navigator.pop(sheet, _Choice(song)),
              ),
            ListTile(
              leading: const Icon(Icons.block_rounded),
              title: const Text('None of these'),
              onTap: () => Navigator.pop(sheet, const _Choice(null)),
            ),
          ],
        ),
      ),
    );
    if (choice != null) setState(() => _choices[i] = choice.song);
  }

  Future<void> _save() async {
    final imports = context.read<ImportsController>();
    final navigator = Navigator.of(context);
    setState(() => _isSaving = true);
    final playlist = await imports.add(widget.playlist.name, [
      for (var i = 0; i < _tracks.length; i++)
        ImportEntry(
          title: _tracks[i].track.title,
          artist: _tracks[i].track.artist,
          album: _tracks[i].track.album,
          durationSeconds: _tracks[i].track.durationSeconds,
          songId: _songAt(i)?.id,
          isUserChoice: _choices.containsKey(i),
        ),
    ]);
    navigator.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ImportedPlaylistPage(playlistId: playlist.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final matched = [
      for (var i = 0; i < _tracks.length; i++)
        if (_songAt(i) != null) i,
    ].length;
    final toCheck = [
      for (var i = 0; i < _tracks.length; i++)
        if (_tracks[i].match.status == MatchStatus.check &&
            !_choices.containsKey(i))
          i,
    ].length;
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            widget.playlist.name,
            style: yomiText(18, weight: FontWeight.w800),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(kPagePadding),
            child: FilledButton(
              onPressed: _isSaving ? null : _save,
              child: Text(
                'Save playlist ($matched of ${_tracks.length} found)',
              ),
            ),
          ),
        ),
        body: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(kPagePadding),
              child: Text(
                [
                  if (widget.mayBeIncomplete)
                    "Spotify's page may only show part of a long playlist, so "
                        'this might be incomplete. A file from your Spotify data '
                        'has every song.',
                  if (toCheck > 0) '$toCheck songs need a quick check.',
                  if (_tracks.length > matched)
                    "Songs you don't have keep their place and fill in once "
                        'they\'re in your library.',
                ].join(' '),
                style: yomiText(
                  13.5,
                  weight: FontWeight.w500,
                  color: YomiColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
            for (var i = 0; i < _tracks.length; i++) _row(i),
          ],
        ),
      ),
    );
  }

  Widget _row(int i) {
    final track = _tracks[i];
    final song = _songAt(i);
    final isChosen = _choices.containsKey(i);
    final (icon, label) = song == null
        ? (Icons.remove_circle_outline_rounded, "Not in your library")
        : track.match.status == MatchStatus.check && !isChosen
        ? (Icons.help_outline_rounded, 'Check: ${song.artist} · ${song.title}')
        : (Icons.check_circle_outline_rounded, song.artist);
    return ListTile(
      leading: Icon(icon),
      title: Text(
        '${i + 1}. ${track.track.title}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: yomiText(14.5, weight: FontWeight.w600),
      ),
      subtitle: Text(
        '${track.track.artist}\n$label',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      onTap: track.match.alternatives.isEmpty ? null : () => _choose(i),
    );
  }
}

class _Choice {
  const _Choice(this.song);

  final Song? song;
}
