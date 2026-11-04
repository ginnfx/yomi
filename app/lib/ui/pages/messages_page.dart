import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/messaging/messaging_api.dart';
import '../../state/messages_controller.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';

void openMessages(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const MessagesPage()));
}

const String _privacyNote =
    "Messages aren't end-to-end encrypted, so whoever runs the server could read them.";

/// Conversations, plus everyone on this server to start a new one with.
class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final messages = context.watch<MessagesController>();
    final me = context.read<SessionController>().username.toLowerCase();
    final talkedTo = {for (final c in messages.conversations) c.withUser};
    final others = [
      for (final person in messages.people)
        if (person.user != me && !talkedTo.contains(person.user)) person,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('Messages', style: yomiText(20, weight: FontWeight.w800)),
      ),
      body: !messages.isAvailable
          ? const _Unavailable()
          : RefreshIndicator(
              color: context.accent,
              onRefresh: messages.refresh,
              child: ListView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + YomiSpace.xl,
                ),
                children: [
                  for (final conversation in messages.conversations)
                    _ConversationTile(conversation: conversation),
                  if (others.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        kPagePadding,
                        YomiSpace.xl,
                        kPagePadding,
                        YomiSpace.s,
                      ),
                      child: Text(
                        'Start a conversation',
                        style: yomiText(16, weight: FontWeight.w800),
                      ),
                    ),
                    for (final person in others)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: kPagePadding,
                        ),
                        leading: _PersonAvatar(profile: person),
                        title: Text(
                          person.name,
                          style: yomiText(15, weight: FontWeight.w700),
                        ),
                        subtitle: person.bio.isEmpty
                            ? null
                            : Text(
                                person.bio,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: yomiText(
                                  13,
                                  weight: FontWeight.w500,
                                  color: YomiColors.textSecondary,
                                ),
                              ),
                        onTap: () => _openThread(context, person.user),
                      ),
                  ],
                  if (messages.conversations.isEmpty && others.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(YomiSpace.xxl),
                      child: Text(
                        "No one else here yet. People appear once they've opened Yomi.",
                        textAlign: TextAlign.center,
                        style: yomiText(
                          14,
                          weight: FontWeight.w500,
                          height: 1.4,
                          color: YomiColors.textSecondary,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      kPagePadding,
                      YomiSpace.xl,
                      kPagePadding,
                      0,
                    ),
                    child: Text(
                      _privacyNote,
                      style: yomiText(
                        12.5,
                        weight: FontWeight.w500,
                        height: 1.35,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

void _openThread(BuildContext context, String user) {
  Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => ThreadPage(user: user)));
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(YomiSpace.xxl),
      child: Text(
        "Messages aren't available on this server right now. If you're on the "
        'backup server, they come back with the main one.',
        textAlign: TextAlign.center,
        style: yomiText(
          14,
          weight: FontWeight.w500,
          height: 1.4,
          color: YomiColors.textSecondary,
        ),
      ),
    ),
  );
}

class _PersonAvatar extends StatelessWidget {
  const _PersonAvatar({required this.profile});

  static const double _radius = 20;

  final ChatProfile profile;

  @override
  Widget build(BuildContext context) {
    final transport = context.read<MessagesController>().transport;
    final initial = profile.name.isEmpty
        ? '?'
        : profile.name.characters.first.toUpperCase();
    return CircleAvatar(
      radius: _radius,
      backgroundColor: YomiColors.surfaceHigh,
      foregroundImage: profile.hasAvatar && transport != null
          ? NetworkImage(transport.avatarUri(profile.user).toString())
          : null,
      child: Text(
        initial,
        style: yomiText(_radius * 0.8, weight: FontWeight.w700),
      ),
    );
  }
}

String _previewOf(ChatMessage message) => message.text.isNotEmpty
    ? message.text
    : '♪ ${message.songTitle ?? 'A song'}';

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation});

  final ChatConversation conversation;

  @override
  Widget build(BuildContext context) {
    final profile = context.read<MessagesController>().profileOf(
      conversation.withUser,
    );
    final hasUnread = conversation.unread > 0;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: kPagePadding),
      leading: _PersonAvatar(profile: profile),
      title: Text(profile.name, style: yomiText(15, weight: FontWeight.w700)),
      subtitle: Text(
        _previewOf(conversation.last),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: yomiText(
          13,
          weight: hasUnread ? FontWeight.w700 : FontWeight.w500,
          color: hasUnread ? YomiColors.textPrimary : YomiColors.textSecondary,
        ),
      ),
      trailing: hasUnread
          ? Semantics(
              label: '${conversation.unread} unread',
              excludeSemantics: true,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: YomiSpace.s,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: context.accent,
                  borderRadius: BorderRadius.circular(YomiRadius.pill),
                ),
                child: Text(
                  '${conversation.unread}',
                  style: yomiText(
                    12,
                    weight: FontWeight.w800,
                    color: Colors.black,
                  ),
                ),
              ),
            )
          : null,
      onTap: () => _openThread(context, conversation.withUser),
    );
  }
}

/// One conversation. Messages poll while it's open.
class ThreadPage extends StatefulWidget {
  const ThreadPage({super.key, required this.user});

  final String user;

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage> {
  final _text = TextEditingController();
  late final MessagesController _messages = context.read<MessagesController>();
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    // Opening notifies listeners, which isn't allowed during this first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_messages.openThread(widget.user));
    });
  }

  @override
  void dispose() {
    _messages.closeThread();
    _text.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty || _isSending) return;
    setState(() => _isSending = true);
    final isSent = await _messages.send(text: text);
    if (!mounted) return;
    // A failed message stays in the box, so nothing typed is lost.
    if (isSent) _text.clear();
    setState(() => _isSending = false);
  }

  Future<void> _shareNowPlaying() async {
    final song = context.read<PlayerController>().current;
    if (song == null || _isSending) return;
    setState(() => _isSending = true);
    await _messages.send(
      songId: song.id,
      songTitle: '${song.title} · ${song.artist}',
    );
    if (mounted) setState(() => _isSending = false);
  }

  @override
  Widget build(BuildContext context) {
    final messages = context.watch<MessagesController>();
    final thread = messages.thread;
    final hasSong = context.select<PlayerController, bool>(
      (player) => player.current != null,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          messages.profileOf(widget.user).name,
          style: yomiText(18, weight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(YomiSpace.l),
                itemCount: thread.length,
                itemBuilder: (_, i) => _Bubble(
                  message: thread[thread.length - 1 - i],
                  isMine: thread[thread.length - 1 - i].to == widget.user,
                ),
              ),
            ),
            if (messages.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: YomiSpace.l),
                child: Text(
                  messages.error!,
                  style: yomiText(
                    13,
                    weight: FontWeight.w600,
                    color: YomiColors.danger,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                YomiSpace.s,
                YomiSpace.xs,
                YomiSpace.s,
                YomiSpace.s,
              ),
              child: Row(
                children: [
                  if (hasSong)
                    IconButton(
                      tooltip: 'Share what is playing',
                      icon: const Icon(Icons.music_note_rounded),
                      onPressed: _isSending ? null : _shareNowPlaying,
                    ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 4000,
                      textCapitalization: TextCapitalization.sentences,
                      style: yomiText(15, weight: FontWeight.w500),
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        counterText: '',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Send',
                    icon: const Icon(Icons.send_rounded),
                    onPressed: _isSending ? null : _sendText,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.isMine});

  final ChatMessage message;
  final bool isMine;

  Future<void> _playSong(BuildContext context) async {
    final songId = message.songId;
    if (songId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final player = context.read<PlayerController>();
    final client = context.read<SessionController>().client;
    try {
      await player.playQueue([await client.song(songId)]);
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("That song isn't on this server anymore."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final foreground = isMine ? Colors.black : YomiColors.textPrimary;
    final hasSong = message.songId != null;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: YomiSpace.s),
          child: Material(
            color: isMine ? context.accent : YomiColors.surfaceHigh,
            borderRadius: BorderRadius.circular(YomiRadius.sheet),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: hasSong ? () => _playSong(context) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YomiSpace.m,
                  vertical: YomiSpace.s,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasSong)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.play_circle_rounded,
                            size: 20,
                            color: foreground,
                          ),
                          const SizedBox(width: YomiSpace.xs),
                          Flexible(
                            child: Text(
                              message.songTitle ?? 'A song',
                              style: yomiText(
                                14,
                                weight: FontWeight.w700,
                                color: foreground,
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (message.text.isNotEmpty)
                      Text(
                        message.text,
                        style: yomiText(
                          14.5,
                          weight: FontWeight.w500,
                          height: 1.3,
                          color: foreground,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
