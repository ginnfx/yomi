import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/messaging/messaging_api.dart';
import '../../state/messages_controller.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/message_entrance.dart';
import '../widgets/message_share_card.dart';
import '../widgets/person_avatar.dart';
import '../widgets/song_picker_sheet.dart';
import 'collection_page.dart';
import 'friend_profile_page.dart';
import '../widgets/yomi_refresh.dart';

void openMessages(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(yomiRoute<void>(builder: (_) => const MessagesPage()));
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
          : YomiRefresh(
              onRefresh: messages.refresh,
              child: ListView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + YomiSpace.xl,
                ),
                children: [
                  _FriendsRow(
                    people: [
                      for (final person in messages.people)
                        if (person.user != me) person,
                    ],
                  ),
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
                        leading: PersonAvatar(profile: person),
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

/// Everyone on the server, to open their profile in one tap.
class _FriendsRow extends StatelessWidget {
  const _FriendsRow({required this.people});

  final List<ChatProfile> people;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(kPagePadding, 12, kPagePadding, 8),
        itemCount: people.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, i) => GestureDetector(
          onTap: () => openProfile(context, people[i].user),
          child: SizedBox(
            width: 64,
            child: Column(
              children: [
                PersonAvatar(profile: people[i], radius: 28),
                const SizedBox(height: 6),
                Text(
                  people[i].name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(12, weight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _openThread(BuildContext context, String user) {
  Navigator.of(context)
      .push(yomiRoute<void>(builder: (_) => ThreadPage(user: user)));
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
      leading: GestureDetector(
        onTap: () => openProfile(context, profile.user),
        child: PersonAvatar(profile: profile),
      ),
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
                    color: context.onAccent,
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
  ChatMessage? _replyingTo;

  /// Messages shown while the chat was loading just appear; later ones animate in.
  static const Duration _settleTime = Duration(milliseconds: 1500);
  final DateTime _openedAt = DateTime.now();
  final Set<int> _known = {};

  bool _isNew(ChatMessage message) {
    final isSettled = DateTime.now().difference(_openedAt) > _settleTime;
    final isKnown = !_known.add(message.id);
    return isSettled && !isKnown;
  }

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
    final submitted = _text.value;
    final reply = _replyingTo;
    final text = submitted.text.trim();
    if (text.isEmpty || _isSending) return;
    setState(() => _isSending = true);
    final isSent = await _messages.send(text: text, replyTo: reply?.id);
    if (!mounted) return;
    // A refused message stays in the box, so nothing typed is lost.
    if (isSent) {
      if (_text.value == submitted) _text.clear();
      if (identical(_replyingTo, reply)) _replyingTo = null;
    }
    setState(() => _isSending = false);
  }

  Future<void> _sendMusic() async {
    if (_isSending) return;
    final picked = await pickMusicToSend(context);
    if (picked == null || !mounted) return;
    setState(() => _isSending = true);
    final message = picked.message;
    await _messages.send(
      songId: message.songId,
      songTitle: message.songTitle,
      albumId: message.albumId,
      playlistId: message.playlistId,
    );
    if (mounted) setState(() => _isSending = false);
  }

  void _showActions(ChatMessage message) {
    if (message.isPending) return;
    final me = context.read<SessionController>().username;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(YomiSpace.s),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final emoji in _reactions)
                    IconButton(
                      icon: Text(emoji, style: const TextStyle(fontSize: 26)),
                      onPressed: () {
                        Navigator.pop(sheet);
                        final isSame = message.reactions[me] == emoji;
                        unawaited(
                          _messages.react(message.id, isSame ? '' : emoji),
                        );
                      },
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(sheet);
                setState(() => _replyingTo = message);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = context.watch<MessagesController>();
    final thread = messages.thread;
    final replying = _replyingTo;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => openProfile(context, widget.user),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PersonAvatar(
                profile: messages.profileOf(widget.user),
                radius: 16,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  messages.profileOf(widget.user).name,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(18, weight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'View profile',
            icon: const Icon(Icons.person_outline_rounded),
            onPressed: () => openProfile(context, widget.user),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(YomiSpace.l),
                itemCount: thread.length + (messages.mayHaveOlder ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == thread.length) {
                    return Center(
                      child: TextButton(
                        onPressed: messages.loadOlder,
                        child: const Text('Load earlier messages'),
                      ),
                    );
                  }
                  final message = thread[thread.length - 1 - i];
                  final isMine = message.to == widget.user;
                  return MessageEntrance(
                    key: ValueKey(message.id),
                    animate: _isNew(message),
                    isMine: isMine,
                    child: _Bubble(
                      message: message,
                      isMine: isMine,
                      repliedTo: thread
                          .where((other) => other.id == message.replyTo)
                          .firstOrNull,
                      onLongPress: () => _showActions(message),
                    ),
                  );
                },
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
            AnimatedSize(
              duration: context.motion(YomiMotion.standard),
              curve: YomiMotion.curve,
              child: replying == null
                  ? const SizedBox(width: double.infinity)
                  : ListTile(
                      dense: true,
                      leading: const Icon(Icons.reply_rounded),
                      title: Text(
                        _preview(replying),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Cancel reply',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _replyingTo = null),
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
                  IconButton(
                    tooltip: 'Send music',
                    icon: const Icon(Icons.music_note_rounded),
                    onPressed: _isSending ? null : _sendMusic,
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

const List<String> _reactions = ['❤️', '🔥', '😂', '😮', '😢', '👍'];

String _preview(ChatMessage message) =>
    message.text.isNotEmpty ? message.text : (message.songTitle ?? 'A share');

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.isMine,
    this.repliedTo,
    this.onLongPress,
  });

  final ChatMessage message;
  final bool isMine;
  final ChatMessage? repliedTo;
  final VoidCallback? onLongPress;

  /// Plays a shared song, or opens a shared album or playlist.
  Future<void> _openShare(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final player = context.read<PlayerController>();
    final client = context.read<SessionController>().client;
    final navigator = Navigator.of(context);
    final title = message.songTitle ?? 'Shared with you';
    try {
      if (message.songId case final id?) {
        await player.playQueue([await client.song(id)]);
      } else if (message.albumId case final id?) {
        await navigator.push(
          yomiRoute<void>(
            builder: (_) => CollectionPage(
              title: title,
              subtitle: '',
              savedSongs: client.cachedAlbumSongs(id),
              kind: CollectionKind.album,
              loadSongs: () => client.albumSongs(id),
            ),
          ),
        );
      } else if (message.playlistId case final id?) {
        await navigator.push(
          yomiRoute<void>(
            builder: (_) => CollectionPage(
              title: title,
              subtitle: '',
              savedSongs: client.cachedPlaylistSongs(id),
              loadSongs: () => client.playlistSongs(id),
            ),
          ),
        );
      }
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(content: Text("That isn't on this server anymore.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final foreground = isMine ? context.onAccent : YomiColors.textPrimary;
    final hasShare = message.isShare;
    final quoted = repliedTo;
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
              onLongPress: onLongPress,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: hasShare ? YomiSpace.xs : YomiSpace.m,
                  vertical: hasShare ? YomiSpace.xs : YomiSpace.s,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (quoted != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: YomiSpace.xs),
                        child: Text(
                          _preview(quoted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: yomiText(
                            12.5,
                            weight: FontWeight.w500,
                            color: foreground.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    if (hasShare)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: message.text.isEmpty ? 0 : YomiSpace.xs,
                        ),
                        child: MessageShareCard(
                          message: message,
                          isMine: isMine,
                          onOpen: () => _openShare(context),
                        ),
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
                    if (message.reactions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: YomiSpace.xs),
                        child: Text(
                          message.reactions.values.join(' '),
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    if (message.isPending)
                      Padding(
                        padding: const EdgeInsets.only(top: YomiSpace.xs),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.schedule_rounded,
                              size: 12,
                              color: foreground.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Sending when connected',
                              style: yomiText(
                                11,
                                weight: FontWeight.w500,
                                color: foreground.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
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
