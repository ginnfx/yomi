import 'package:flutter/widgets.dart';

import '../../state/messages_controller.dart';
import '../messaging/messaging_api.dart';
import 'notification_sink.dart';

const int _maxBodyChars = 120;

/// Tells you about new messages while Yomi isn't on screen. Messages that were
/// already waiting when the app opened, and chats you are looking at, stay quiet.
class MessageNotifier with WidgetsBindingObserver {
  MessageNotifier({
    required this.messages,
    required this.sink,
    required this.isEnabled,
    required this.nameOf,
    this.isInForeground,
  });

  final MessagesController messages;
  final NotificationSink sink;
  final bool Function() isEnabled;
  final String Function(String user) nameOf;

  /// Replaces the real app state, for tests.
  final bool Function()? isInForeground;

  final Map<String, int> _lastSeen = {};
  bool _hasBaseline = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  bool get _isForeground =>
      isInForeground?.call() ?? _lifecycle == AppLifecycleState.resumed;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    messages.addListener(_onMessages);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    messages.removeListener(_onMessages);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    // Anything you were told about is read once you're back.
    if (state == AppLifecycleState.resumed) sink.cancelAll();
  }

  /// Forgets what was seen, for the next person to sign in.
  void reset() {
    _lastSeen.clear();
    _hasBaseline = false;
  }

  void _onMessages() {
    final conversations = messages.conversations;
    if (!_hasBaseline) {
      // People arrive with the first fetch, so a quiet inbox still gets a baseline.
      if (!messages.isAvailable || messages.people.isEmpty) return;
      for (final conversation in conversations) {
        _lastSeen[conversation.withUser] = conversation.last.id;
      }
      _hasBaseline = true;
      return;
    }
    for (final conversation in conversations) {
      final previous = _lastSeen[conversation.withUser] ?? 0;
      final last = conversation.last;
      if (last.id <= previous) continue;
      _lastSeen[conversation.withUser] = last.id;
      if (last.from != conversation.withUser || conversation.unread == 0) {
        continue;
      }
      if (!isEnabled() || _isForeground) continue;
      _notify(conversation);
    }
  }

  void _notify(ChatConversation conversation) {
    final from = nameOf(conversation.withUser);
    final last = conversation.last;
    final count = conversation.unread;
    final body = _bodyOf(last);
    sink.show(
      id: conversation.withUser.hashCode & 0x7fffffff,
      title: count > 1 ? '$from · $count new messages' : from,
      body: body,
      payload: conversation.withUser,
    );
  }

  static String _bodyOf(ChatMessage message) {
    final text = message.text.trim();
    final share = message.songTitle;
    final shared = share == null
        ? (message.isShare ? 'Shared something with you' : '')
        : 'Shared "$share"';
    final body = text.isEmpty ? shared : text;
    if (body.isEmpty) return 'New message';
    return body.length <= _maxBodyChars
        ? body
        : '${body.substring(0, _maxBodyChars - 1)}…';
  }
}
