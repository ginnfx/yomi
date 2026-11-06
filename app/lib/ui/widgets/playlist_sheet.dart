import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/session.dart';
import '../theme.dart';
import 'async_section.dart';

/// Bottom sheet that adds [song] to an existing playlist or a new one.
Future<void> showAddToPlaylist(BuildContext context, Song song) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PlaylistPicker(song: song, parentContext: context),
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
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = context.read<SessionController>().client;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                8,
                kPagePadding,
                8,
              ),
              child: Text(
                'Add to playlist',
                style: yomiText(20, weight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
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
            Flexible(
              child: AsyncSection<List<Playlist>>(
                load: client.playlists,
                builder: (context, playlists) => ListView(
                  shrinkWrap: true,
                  children: [
                    for (final playlist in playlists)
                      ListTile(
                        leading: const Icon(Icons.queue_music_rounded),
                        title: Text(playlist.name),
                        subtitle: Text(
                          '${playlist.songCount} songs',
                          style: TextStyle(color: YomiColors.textSecondary),
                        ),
                        onTap: () => _run(
                          context,
                          () => client.addToPlaylist(playlist.id, [song.id]),
                          'Added to ${playlist.name}',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
