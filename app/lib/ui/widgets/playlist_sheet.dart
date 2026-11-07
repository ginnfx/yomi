import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/spotify/imported_playlist.dart';
import '../../state/catalog_controller.dart';
import '../../state/imports_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import 'async_section.dart';
import 'playlist_cover.dart';
import 'shimmer.dart';
import 'error_view.dart';

/// How much of the screen the sheet takes.
const double _sheetHeight = 0.7;

const double _coverSize = 48;

/// Bottom sheet that adds [song] to an existing playlist or a new one.
Future<void> showAddToPlaylist(BuildContext context, Song song) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: YomiColors.surface,
    // A fixed height, so the sheet doesn't resize when the playlists arrive.
    builder: (_) => FractionallySizedBox(
      heightFactor: _sheetHeight,
      child: _PlaylistPicker(song: song, parentContext: context),
    ),
  );
}

Future<String?> promptForName(
  BuildContext context, {
  String title = 'New playlist',
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: YomiColors.surface,
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class _PlaylistPicker extends StatelessWidget {
  const _PlaylistPicker({required this.song, required this.parentContext});

  final Song song;
  final BuildContext parentContext;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String doneMessage,
  ) async {
    final messenger = ScaffoldMessenger.of(parentContext);
    Navigator.pop(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(doneMessage)));
    } on Exception catch (error) {
      if (parentContext.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(failureMessage(parentContext, error))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = context.read<SessionController>().client;
    final imports = context.watch<ImportsController>();
    final covers = {
      for (final s in context.read<CatalogController>().songs)
        s.id: s.coverArtId,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 8),
          child: Text(
            'Add to playlist',
            style: yomiText(20, weight: FontWeight.w800),
          ),
        ),
        ListTile(
          leading: const SizedBox(
            width: _coverSize,
            child: Icon(Icons.add_rounded),
          ),
          title: const Text('New playlist'),
          onTap: () async {
            final name = await promptForName(context);
            if (name == null || name.isEmpty || !context.mounted) return;
            await _run(
              context,
              () => client.createPlaylist(name, songIds: [song.id]),
              'Added to $name',
            );
          },
        ),
        Expanded(
          child: AsyncSection<List<Playlist>>(
            load: client.playlists,
            initialData: client.cachedPlaylists,
            // Clipped, so the loading placeholder can't spill out of a short sheet.
            skeleton: const ClipRect(
              child: SingleChildScrollView(
                physics: NeverScrollableScrollPhysics(),
                child: SongListSkeleton(),
              ),
            ),
            builder: (context, playlists) => ListView(
              children: [
                for (final playlist in playlists)
                  _row(
                    context,
                    playlistId: playlist.id,
                    name: playlist.name,
                    count: playlist.songCount,
                    coverArtId: playlist.coverArtId,
                    onTap: () => _run(
                      context,
                      () => client.addToPlaylist(playlist.id, [song.id]),
                      'Added to ${playlist.name}',
                    ),
                  ),
                for (final imported in imports.playlists)
                  _row(
                    context,
                    playlistId: imported.id,
                    name: imported.name,
                    count: imported.entries.length,
                    coverArtId: _firstCover(imported, covers),
                    onTap: () => _run(
                      context,
                      () => imports.update(imported.withSongAdded(song)),
                      'Added to ${imported.name}',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String? _firstCover(ImportedPlaylist playlist, Map<String, String?> covers) {
    for (final entry in playlist.entries) {
      final art = covers[entry.songId];
      if (art != null) return art;
    }
    return null;
  }

  Widget _row(
    BuildContext context, {
    required String playlistId,
    required String name,
    required int count,
    required String? coverArtId,
    required VoidCallback onTap,
  }) => ListTile(
    leading: PlaylistCover(
      playlistId: playlistId,
      coverArtId: coverArtId,
      size: _coverSize,
      radius: YomiRadius.art,
      seed: name,
    ),
    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      '$count songs',
      style: TextStyle(color: YomiColors.textSecondary),
    ),
    onTap: onTap,
  );
}
