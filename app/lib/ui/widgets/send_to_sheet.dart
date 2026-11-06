import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/messaging/messaging_api.dart';
import '../../state/messages_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import 'person_avatar.dart';

/// Friends to offer when sending something, most recently talked to first, so a share
/// is usually one tap.
List<ChatProfile> sendCandidates(MessagesController messages, String me) {
  final lastTalked = {
    for (final chat in messages.conversations) chat.withUser: chat.last.sentAt,
  };
  return [
    for (final person in messages.people)
      if (person.user != me) person,
  ]..sort((a, b) {
    final first = lastTalked[a.user];
    final second = lastTalked[b.user];
    if (first == null || second == null) {
      return (first == null ? 1 : 0) - (second == null ? 1 : 0);
    }
    return second.compareTo(first);
  });
}

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
  final people = sendCandidates(
    messages,
    context.read<SessionController>().username,
  );
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
                    leading: PersonAvatar(profile: person),
                    title: Text(
                      person.name,
                      style: yomiText(15, weight: FontWeight.w700),
                    ),
                    trailing: Icon(Icons.send_rounded, color: context.accent),
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
