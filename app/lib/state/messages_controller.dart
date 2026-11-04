import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/messaging/messaging_api.dart';

const Duration kInboxPollEvery = Duration(seconds: 30);
const Duration kThreadPollEvery = Duration(seconds: 5);

/// Holds conversations and keeps them fresh by polling. Push, when set up, only makes
/// messages appear sooner: nothing depends on it.
class MessagesController extends ChangeNotifier {
  MessagesController({
    this.inboxPollEvery = kInboxPollEvery,
    this.threadPollEvery = kThreadPollEvery,
  });

  final Duration inboxPollEvery;
  final Duration threadPollEvery;
  MessagingTransport? _transport;
  Timer? _inboxTimer;
  Timer? _threadTimer;
  bool _isDisposed = false;
  bool _isAvailable = true;
  bool _isPolling = false;
  List<ChatConversation> _conversations = const [];
  List<ChatProfile> _people = const [];
  String? _openThread;
  List<ChatMessage> _thread = const [];

  /// The newest message found by polling. It ignores messages sent from here, or a
  /// friend's message that arrived just before one of ours would never be fetched.
  int _pollCursor = 0;
  String? _error;

  /// False when the server has no messaging, such as the backup server.
  bool get isAvailable => _isAvailable;
  List<ChatConversation> get conversations => _conversations;
  List<ChatProfile> get people => _people;
  List<ChatMessage> get thread => _thread;
  String? get error => _error;
  int get unreadTotal => _conversations.fold(
    0,
    (total, conversation) => total + conversation.unread,
  );
  MessagingTransport? get transport => _transport;

  ChatProfile profileOf(String user) => _people.firstWhere(
    (person) => person.user == user,
    orElse: () => ChatProfile(user: user),
  );

  /// Connects to a server, or stops everything with null.
  void attach(MessagingTransport? transport) {
    _transport = transport;
    _inboxTimer?.cancel();
    if (transport == null) {
      _threadTimer?.cancel();
      _conversations = const [];
      _people = const [];
      _thread = const [];
      _openThread = null;
      _changed();
      return;
    }
    _isAvailable = true;
    _inboxTimer = Timer.periodic(inboxPollEvery, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  /// Fetches the inbox and people. A failed poll keeps what's on screen and stays quiet,
  /// since the next one is moments away.
  Future<void> refresh() async {
    final transport = _transport;
    if (transport == null || _isPolling) return;
    _isPolling = true;
    try {
      final results = await Future.wait([
        transport.conversations(),
        transport.profiles(),
      ]);
      _conversations = results[0] as List<ChatConversation>;
      _people = results[1] as List<ChatProfile>;
      _isAvailable = true;
    } on MessagingUnavailable {
      _isAvailable = false;
    } on MessagingException catch (error) {
      debugPrint('Could not refresh messages: $error');
    } finally {
      _isPolling = false;
      _changed();
    }
  }

  /// Publishes this user's name and bio, so friends see them. Also how a user becomes
  /// someone others can message.
  Future<void> publishProfile({
    required String displayName,
    required String bio,
    File? avatar,
  }) async {
    final transport = _transport;
    if (transport == null) return;
    try {
      await transport.saveProfile(displayName: displayName, bio: bio);
      if (avatar != null) await transport.saveAvatar(avatar);
    } on MessagingUnavailable {
      _isAvailable = false;
      _changed();
    } on MessagingException catch (error) {
      debugPrint('Could not publish profile: $error');
    }
  }

  Future<void> openThread(String user) async {
    _openThread = user;
    _thread = const [];
    _pollCursor = 0;
    _error = null;
    _threadTimer?.cancel();
    _threadTimer = Timer.periodic(
      threadPollEvery,
      (_) => unawaited(_pullThread()),
    );
    _changed();
    await _pullThread();
  }

  void closeThread() {
    _openThread = null;
    _thread = const [];
    _threadTimer?.cancel();
    unawaited(refresh());
  }

  @visibleForTesting
  Future<void> pollThreadForTest() => _pullThread();

  Future<void> _pullThread() async {
    final user = _openThread;
    final transport = _transport;
    if (user == null || transport == null) return;
    try {
      final fresh = await transport.thread(user, after: _pollCursor);
      if (user != _openThread) return; // Moved to another thread meanwhile.
      if (fresh.isEmpty) return;
      _pollCursor = fresh.last.id;
      _thread = List.unmodifiable(_merge(_thread, fresh));
      _changed();
      await transport.markRead(user, _thread.last.id);
    } on MessagingUnavailable {
      _isAvailable = false;
      _changed();
    } on MessagingException catch (error) {
      debugPrint('Could not refresh this conversation: $error');
    }
  }

  /// A polled reply can overlap one just sent, so messages are matched by id.
  static List<ChatMessage> _merge(
    List<ChatMessage> existing,
    List<ChatMessage> fresh,
  ) {
    final known = existing.map((message) => message.id).toSet();
    return [
      ...existing,
      ...fresh.where((message) => !known.contains(message.id)),
    ]..sort((a, b) => a.id.compareTo(b.id));
  }

  /// Returns false and sets [error] if the message couldn't be sent, so the text can stay
  /// in the box to try again.
  Future<bool> send({
    String text = '',
    String? songId,
    String? songTitle,
  }) async {
    final user = _openThread;
    final transport = _transport;
    if (user == null || transport == null) return false;
    _error = null;
    try {
      final sent = await transport.send(
        user,
        text: text,
        songId: songId,
        songTitle: songTitle,
      );
      if (user == _openThread) {
        _thread = List.unmodifiable(_merge(_thread, [sent]));
      }
      _changed();
      return true;
    } on MessagingUnavailable {
      _isAvailable = false;
      _error = "Messages aren't available on this server right now.";
    } on MessagingException catch (error) {
      _error = error.message;
    }
    _changed();
    return false;
  }

  void _changed() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _inboxTimer?.cancel();
    _threadTimer?.cancel();
    super.dispose();
  }
}
