import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/messaging/messaging_api.dart';

const Duration kInboxPollEvery = Duration(seconds: 30);
const Duration kThreadPollEvery = Duration(seconds: 5);

/// Waiting this long after a failed wait for events, so a server that's away isn't hammered.
const Duration _eventRetryAfter = Duration(seconds: 15);
const Duration _eventMinWait = Duration(seconds: 1);

/// Holds conversations and keeps them fresh by polling. Push, when set up, only makes
/// messages appear sooner: nothing depends on it.
class MessagesController extends ChangeNotifier {
  MessagesController({
    this.inboxPollEvery = kInboxPollEvery,
    this.threadPollEvery = kThreadPollEvery,
    this.savedChats,
    this.me,
    this.listenForEvents = false,
  });

  /// Where chats are kept on this device. Without it nothing is saved.
  final Directory? savedChats;

  /// The signed-in user, for showing messages written here before they're sent.
  final String Function()? me;

  /// Whether to hold a connection open so new messages arrive at once.
  final bool listenForEvents;
  int _listenGeneration = 0;
  int _revision = -1;
  List<ChatMessage> _pending = const [];
  bool _isFlushing = false;
  bool _mayHaveOlder = true;
  Future<void> _writes = Future.value();
  int _lastLocalId = 0;

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

  /// The open chat, with anything still on its way at the end.
  List<ChatMessage> get thread => [
    ..._thread,
    ..._pending.where((message) => message.to == _openThread),
  ];

  /// Whether there may be earlier messages to fetch.
  bool get mayHaveOlder => _mayHaveOlder;

  /// What friends who chose to share are listening to.
  List<ChatProfile> get friendsPlaying => [
    for (final person in _people)
      if (person.nowPlaying != null && person.user != me?.call()) person,
  ];
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
    _sharedTasteKey = null;
    _inboxTimer?.cancel();
    _listenGeneration++;
    if (transport == null) {
      _threadTimer?.cancel();
      _conversations = const [];
      _people = const [];
      _thread = const [];
      _pending = const [];
      _openThread = null;
      _revision = -1;
      _queueWrite(_deleteSaved);
      _changed();
      return;
    }
    _isAvailable = true;
    _queueWrite(_loadPending);
    if (listenForEvents) unawaited(_listen(_listenGeneration));
    _inboxTimer = Timer.periodic(inboxPollEvery, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  /// Holds a request open until something new happens, then refreshes. This replaces
  /// frequent polling: the server waits cheaply, and messages arrive within moments.
  Future<void> _listen(int generation) async {
    while (generation == _listenGeneration && !_isDisposed) {
      final transport = _transport;
      if (transport == null) return;
      try {
        final startedAt = DateTime.now();
        final revision = await transport.waitForChange(_revision);
        if (generation != _listenGeneration || _isDisposed) return;
        if (revision != _revision) {
          _revision = revision;
          await Future.wait([refresh(), refreshOpenThread(), flushPending()]);
        } else if (DateTime.now().difference(startedAt) < _eventMinWait) {
          // A real wait takes a while. An instant "nothing new" must not become a tight loop.
          await Future<void>.delayed(_eventMinWait);
        }
      } on MessagingUnavailable {
        return; // This server has no messaging, and the inbox timer will notice if that changes.
      } on MessagingException catch (error) {
        debugPrint('Waiting for messages failed: $error');
        await Future<void>.delayed(_eventRetryAfter);
      }
    }
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
  Future<bool> publishProfile({
    required String displayName,
    required String bio,
    File? avatar,
    File? banner,
  }) async {
    final transport = _transport;
    if (transport == null) return false;
    try {
      await transport.saveProfile(displayName: displayName, bio: bio);
      if (avatar != null) await transport.saveAvatar(avatar);
      if (banner != null) await transport.saveBanner(banner);
      // Friends' lists carry the new picture version only after a refresh.
      if (avatar != null || banner != null) unawaited(refresh());
      return true;
    } on MessagingUnavailable {
      _isAvailable = false;
      _changed();
    } on MessagingException catch (error) {
      debugPrint('Could not publish profile: $error');
    }
    return false;
  }

  /// A person's current picture or banner from the server, or null if they have none
  /// or it can't be reached right now.
  Future<List<int>?> fetchPersonImage(
    ChatProfile person, {
    required bool isBanner,
  }) async {
    final transport = _transport;
    if (transport == null) return null;
    try {
      return await transport.fetchImage(
        isBanner
            ? transport.bannerUri(person.user, version: person.bannerVersion)
            : transport.avatarUri(person.user, version: person.avatarVersion),
      );
    } on MessagingException catch (error) {
      debugPrint('Could not fetch ${person.user}\'s picture: $error');
      return null;
    }
  }

  /// Tells the server where to push this phone. Quiet on failure: it is tried again
  /// the next time the app signs in or starts.
  Future<bool> registerDevice({
    required String token,
    required String kind,
  }) async {
    final transport = _transport;
    if (transport == null) return false;
    try {
      await transport.registerDevice(token: token, kind: kind);
      return true;
    } on MessagingException catch (error) {
      debugPrint('Could not register for push: $error');
      return false;
    }
  }

  Future<void> openThread(String user) async {
    _openThread = user;
    _thread = const [];
    _threadTimer?.cancel();
    final saved = await _readSaved(user);
    // Left, or moved to another chat, while reading from disk.
    if (user != _openThread) return;
    _thread = saved;
    _mayHaveOlder = true;
    _pollCursor = _thread.isEmpty ? 0 : _thread.last.id;
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
      _saveThread(user);
      _changed();
      await transport.markRead(user, _thread.last.id);
    } on MessagingUnavailable {
      _isAvailable = false;
      _changed();
    } on MessagingException catch (error) {
      debugPrint('Could not refresh this conversation: $error');
    }
  }

  /// A polled reply can overlap one just sent, so messages are matched by id. The newer
  /// copy wins, as it may carry new reactions.
  static List<ChatMessage> _merge(
    List<ChatMessage> existing,
    List<ChatMessage> fresh,
  ) {
    final byId = {
      for (final message in existing) message.id: message,
      for (final message in fresh) message.id: message,
    };
    return byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  /// Fetches the newest page again, to pick up changes to messages already here, such as
  /// reactions. Polling for new messages alone would never see those.
  Future<void> refreshOpenThread() async {
    final user = _openThread;
    final transport = _transport;
    if (user == null || transport == null) return;
    try {
      final latest = await transport.thread(user);
      if (user != _openThread || latest.isEmpty) return;
      _thread = List.unmodifiable(_merge(_thread, latest));
      _pollCursor = _thread.last.id;
      _saveThread(user);
      _changed();
    } on MessagingUnavailable {
      _isAvailable = false;
      _changed();
    } on MessagingException catch (error) {
      debugPrint('Could not refresh this conversation: $error');
    }
  }

  /// Fetches the page before what's showing. Once a page comes back empty, that's all.
  Future<void> loadOlder() async {
    final user = _openThread;
    final transport = _transport;
    if (user == null || transport == null || _thread.isEmpty) return;
    try {
      final older = await transport.thread(user, before: _thread.first.id);
      if (user != _openThread) return;
      if (older.isEmpty) {
        _mayHaveOlder = false;
      } else {
        _thread = List.unmodifiable(_merge(_thread, older));
        _saveThread(user);
      }
      _changed();
    } on MessagingException catch (error) {
      debugPrint('Could not load older messages: $error');
    }
  }

  /// Sets or, with an empty [emoji], removes your reaction. Shown straight away.
  Future<void> react(int messageId, String emoji) async {
    final transport = _transport;
    final user = me?.call();
    if (transport == null || user == null) return;
    final before = _thread;
    _thread = List.unmodifiable([
      for (final message in _thread)
        message.id == messageId ? _withReaction(message, user, emoji) : message,
    ]);
    _changed();
    try {
      await transport.react(messageId, emoji);
      final open = _openThread;
      if (open != null) _saveThread(open);
    } on MessagingException catch (error) {
      debugPrint('Could not save a reaction: $error');
      _thread = before;
      _error = "Couldn't add that reaction.";
      _changed();
    }
  }

  static ChatMessage _withReaction(
    ChatMessage message,
    String user,
    String emoji,
  ) => ChatMessage(
    id: message.id,
    from: message.from,
    to: message.to,
    text: message.text,
    sentAt: message.sentAt,
    songId: message.songId,
    songTitle: message.songTitle,
    albumId: message.albumId,
    playlistId: message.playlistId,
    replyTo: message.replyTo,
    reactions: {
      for (final entry in message.reactions.entries)
        if (entry.key != user) entry.key: entry.value,
      if (emoji.isNotEmpty) user: emoji,
    },
  );

  /// Sends to the open chat. See [sendTo].
  Future<bool> send({
    String text = '',
    String? songId,
    String? songTitle,
    String? albumId,
    String? playlistId,
    int? replyTo,
  }) async {
    final user = _openThread;
    if (user == null) return false;
    return sendTo(
      user,
      text: text,
      songId: songId,
      songTitle: songTitle,
      albumId: albumId,
      playlistId: playlistId,
      replyTo: replyTo,
    );
  }

  /// Returns false and sets [error] if the server refused the message, so the text can stay
  /// in the box. If the server just can't be reached, it counts as sent: it shows as pending
  /// and goes when the server's back, even after a restart.
  Future<bool> sendTo(
    String user, {
    String text = '',
    String? songId,
    String? songTitle,
    String? albumId,
    String? playlistId,
    int? replyTo,
  }) async {
    final transport = _transport;
    if (transport == null) return false;
    _error = null;
    final draft = ChatMessage(
      id: _newLocalId(),
      from: me?.call() ?? '',
      to: user,
      text: text,
      sentAt: DateTime.now(),
      songId: songId,
      songTitle: songTitle,
      albumId: albumId,
      playlistId: playlistId,
      replyTo: replyTo,
      isPending: true,
    );
    try {
      final sent = await _deliver(transport, draft);
      if (user == _openThread) {
        _thread = List.unmodifiable(_merge(_thread, [sent]));
        _saveThread(user);
      }
      _changed();
      return true;
    } on MessagingOffline catch (error) {
      debugPrint('A message will be sent later: $error');
      _pending = List.unmodifiable([..._pending, draft]);
      _queueWrite(_savePending);
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

  /// Negative, so it can't be mistaken for a server's ID, and based on the time, so it
  /// can't repeat one saved before a restart.
  int _newLocalId() {
    final now = -DateTime.now().microsecondsSinceEpoch;
    _lastLocalId = now < _lastLocalId ? now : _lastLocalId - 1;
    return _lastLocalId;
  }

  Future<ChatMessage> _deliver(
    MessagingTransport transport,
    ChatMessage draft,
  ) => transport.send(
    draft.to,
    text: draft.text,
    songId: draft.songId,
    songTitle: draft.songTitle,
    albumId: draft.albumId,
    playlistId: draft.playlistId,
    replyTo: draft.replyTo,
  );

  /// Sends messages written while the server was away, oldest first, and stops if it's
  /// still away. One it refuses can never succeed, so it's dropped rather than blocking.
  Future<void> flushPending() async {
    final transport = _transport;
    if (transport == null || _isFlushing) return;
    _isFlushing = true;
    try {
      await _writes;
      while (_pending.isNotEmpty) {
        final draft = _pending.first;
        try {
          final sent = await _deliver(transport, draft);
          if (draft.to == _openThread) {
            _thread = List.unmodifiable(_merge(_thread, [sent]));
            _saveThread(draft.to);
          }
        } on MessagingOffline {
          return;
        } on MessagingUnavailable {
          return;
        } on MessagingException catch (error) {
          debugPrint('Dropping a message the server refused: $error');
        }
        _pending = List.unmodifiable(_pending.skip(1));
        _queueWrite(_savePending);
        _changed();
      }
    } finally {
      _isFlushing = false;
    }
  }

  /// Files are written one at a time, in order, so a later save can't lose to an earlier one.
  void _queueWrite(Future<void> Function() write) {
    _writes = _writes.then((_) => write()).catchError((Object error) {
      debugPrint('Could not save chats: $error');
    });
  }

  @visibleForTesting
  Future<void> savedForTest() => _writes;

  File? _threadFile(String user) {
    final dir = savedChats;
    if (dir == null) return null;
    final safe = base64Url.encode(utf8.encode(user));
    return File('${dir.path}/thread-$safe.json');
  }

  File? get _pendingFile {
    final dir = savedChats;
    return dir == null ? null : File('${dir.path}/pending.json');
  }

  Future<List<ChatMessage>> _readSaved(String user) async {
    await _writes;
    final file = _threadFile(user);
    if (file == null) return const [];
    try {
      if (!await file.exists()) return const [];
      return _decode(await file.readAsString());
    } on Object catch (error) {
      debugPrint('Ignoring a saved chat: $error');
      return const [];
    }
  }

  static List<ChatMessage> _decode(String text) => List.unmodifiable(
    (jsonDecode(text) as List<dynamic>).cast<Map<String, dynamic>>().map(
      ChatMessage.fromJson,
    ),
  );

  void _saveThread(String user) {
    final file = _threadFile(user);
    if (file == null) return;
    final messages = _thread;
    _queueWrite(() => _write(file, messages));
  }

  Future<void> _savePending() async {
    final file = _pendingFile;
    if (file != null) await _write(file, _pending);
  }

  Future<void> _loadPending() async {
    final file = _pendingFile;
    if (file == null || !await file.exists()) return;
    final saved = _decode(await file.readAsString());
    final known = {for (final message in _pending) message.id};
    _pending = List.unmodifiable([
      ...saved.where((message) => !known.contains(message.id)),
      ..._pending,
    ]);
  }

  static Future<void> _write(File file, List<ChatMessage> messages) async {
    final temp = File('${file.path}.tmp');
    await temp.parent.create(recursive: true);
    await temp.writeAsString(
      jsonEncode([for (final message in messages) message.toJson()]),
    );
    await temp.rename(file.path);
  }

  Future<void> _deleteSaved() async {
    final dir = savedChats;
    if (dir == null || !await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File) await entity.delete();
    }
  }

  /// Shares what's playing, if you've chosen to. Failing just means friends see it later.
  Future<void> sharePlaying({
    String? songId,
    String? title,
    String? artist,
  }) async {
    try {
      await _transport?.setPlaying(
        songId: songId,
        title: title,
        artist: artist,
      );
    } on MessagingException catch (error) {
      debugPrint('Could not share what is playing: $error');
    }
  }

  String? _sharedTasteKey;

  /// Shares your top artists and moods with friends, only when they've changed. Empty
  /// lists stop sharing.
  Future<void> shareTaste({
    required List<String> topArtists,
    required List<String> topMoods,
  }) async {
    final transport = _transport;
    final key = '${topArtists.join('|')}#${topMoods.join('|')}';
    if (transport == null || key == _sharedTasteKey) return;
    _sharedTasteKey = key;
    try {
      await transport.saveTaste(topArtists: topArtists, topMoods: topMoods);
    } on MessagingException catch (error) {
      _sharedTasteKey = null;
      debugPrint('Could not share your taste: $error');
    }
  }

  void _changed() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _listenGeneration++;
    _inboxTimer?.cancel();
    _threadTimer?.cancel();
    super.dispose();
  }
}
