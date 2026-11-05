import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/messages_controller.dart';
import '../../state/session.dart';
import '../theme.dart';

/// Asks who to send something to, then sends it. Works for a song, album or playlist.
Future<void> showSendTo(
  BuildContext context, {
  required String title,
  String? songId,
  String? albumId,
  String? playlistId,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final messages = context.read<MessagesController>();
  final me = context.read<SessionController>().username;
  final people = [
    for (final person in messages.people)
      if (person.user != me) person,
  ];
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: people.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                "There's nobody here to send to yet.",
                textAlign: TextAlign.center,
                style: yomiText(
                  14,
                  weight: FontWeight.w500,
                  color: YomiColors.textSecondary,
                ),
              ),
            )
          : ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Send "$title" to…',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: yomiText(16, weight: FontWeight.w800),
                  ),
                ),
                for (final person in people)
                  ListTile(
                    leading: const Icon(Icons.person_rounded),
                    title: Text(person.name),
                    onTap: () async {
                      Navigator.pop(sheet);
                      final isSent = await messages.sendTo(
                        person.user,
                        songId: songId,
                        albumId: albumId,
                        playlistId: playlistId,
                        songTitle: title,
                      );
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            isSent
                                ? 'Sent to ${person.name}'
                                : messages.error ?? "Couldn't send that",
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
    ),
  );
}
