import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/error_view.dart';
import '../widgets/mosaic_cover.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/song_tile.dart';

/// Opens a playlist that isn't saved yet, such as a suggestion or a Blend, to play or save.
Future<void> openPlaylistPreview(
  BuildContext context, {
  required String name,
  required String description,
  required List<Song> songs,
}) => Navigator.of(context).push(
  yomiRoute<void>(
    builder: (_) =>
        PlaylistPreviewPage(name: name, description: description, songs: songs),
  ),
);

class PlaylistPreviewPage extends StatefulWidget {
  const PlaylistPreviewPage({
    super.key,
    required this.name,
    required this.description,
    required this.songs,
  });

  final String name;
  final String description;
  final List<Song> songs;

  @override
  State<PlaylistPreviewPage> createState() => _PlaylistPreviewPageState();
}

class _PlaylistPreviewPageState extends State<PlaylistPreviewPage> {
  late String _name = widget.name;
  late List<Song> _songs = widget.songs;
  bool _isSaving = false;
  bool _isSaved = false;

  Future<void> _rename() async {
    final next = await promptForName(
      context,
      title: 'Name this playlist',
      initial: _name,
    );
    if (next != null && next.trim().isNotEmpty) {
      setState(() => _name = next.trim());
    }
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final client = context.read<SessionController>().client;
    setState(() => _isSaving = true);
    try {
      await client.createPlaylist(
        _name,
        songIds: [for (final song in _songs) song.id],
      );
      await client.refreshPlaylists();
      if (!mounted) return;
      setState(() => _isSaved = true);
      messenger.showSnackBar(SnackBar(content: Text('Saved "$_name"')));
    } on Exception catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeFailure(context, error).title)),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_rounded),
            onPressed: _isSaved ? null : _rename,
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              8,
              kPagePadding,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: MosaicCover(
                    songs: _songs,
                    size: 220,
                    radius: kCardRadius,
                    seed: _name,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _name,
                  style: yomiText(
                    30,
                    weight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
                if (widget.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.description,
                    style: yomiText(15, color: YomiColors.textSecondary),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '${_songs.length} songs',
                  style: yomiText(13, color: YomiColors.textSecondary),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _songs.isEmpty
                          ? null
                          : () => player.playQueue(_songs),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _songs.isEmpty
                          ? null
                          : () async {
                              await player.playQueue(_songs);
                              if (!player.isShuffled) {
                                await player.toggleShuffle();
                              }
                            },
                      icon: const Icon(Icons.shuffle_rounded),
                      label: const Text('Shuffle'),
                    ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: _isSaving || _isSaved || _songs.isEmpty
                          ? null
                          : _save,
                      icon: Icon(
                        _isSaved ? Icons.check_rounded : Icons.add_rounded,
                      ),
                      label: Text(_isSaved ? 'Saved' : 'Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          for (var i = 0; i < _songs.length; i++)
            Dismissible(
              key: ValueKey(_songs[i].id),
              direction: _isSaved
                  ? DismissDirection.none
                  : DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: kPagePadding),
                color: YomiColors.surfaceHigh,
                child: const Icon(Icons.remove_circle_outline_rounded),
              ),
              onDismissed: (_) {
                final removed = _songs[i];
                setState(
                  () => _songs = [
                    for (final song in _songs)
                      if (song.id != removed.id) song,
                  ],
                );
              },
              child: SongTile(
                song: _songs[i],
                onTap: () => player.playQueue(_songs, startIndex: i),
              ),
            ),
          const SizedBox(height: 120),
        ],
      ),
    );
  }
}
