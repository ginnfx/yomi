import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/messaging/messaging_api.dart';
import 'package:yomi/state/messages_controller.dart';

class _Server implements MessagingTransport {
  @override
  Future<void> saveTaste({
    required List<String> topArtists,
    required List<String> topMoods,
  }) async {}

  final List<ChatMessage> messages = [];
  final List<ChatProfile> people = const [ChatProfile(user: 'sam')];
  final reacted = <(int, String)>[];
  Exception? failure;
  int nextId = 1;
  int revision = 1;
  int waits = 0;

  void receive(String text) => messages.add(
    ChatMessage(
      id: nextId++,
      from: 'sam',
      to: 'me',
      text: text,
      sentAt: DateTime(2026),
    ),
  );

  @override
  Future<List<ChatConversation>> conversations() async => const [];

  @override
  Future<List<ChatMessage>> thread(
    String withUser, {
    int after = 0,
    int before = 0,
  }) async {
    final error = failure;
    if (error != null) throw error;
    final found = messages
        .where((m) => m.id > after && (before == 0 || m.id < before))
        .toList();
    const page = 2;
    if (before != 0 || after == 0) {
      return found.length > page ? found.sublist(found.length - page) : found;
    }
    return found;
  }

  @override
  Future<ChatMessage> send(
    String to, {
    String text = '',
    String? songId,
    String? songTitle,
    String? albumId,
    String? playlistId,
    int? replyTo,
  }) async {
    final error = failure;
    if (error != null) throw error;
    final message = ChatMessage(
      id: nextId++,
      from: 'me',
      to: to,
      text: text,
      sentAt: DateTime(2026),
      songId: songId,
      songTitle: songTitle,
      albumId: albumId,
      playlistId: playlistId,
      replyTo: replyTo,
    );
    messages.add(message);
    return message;
  }

  @override
  Future<void> react(int messageId, String emoji) async {
    final error = failure;
    if (error != null) throw error;
    reacted.add((messageId, emoji));
  }

  @override
  Future<int> waitForChange(int revision) async {
    waits++;
    return this.revision;
  }

  @override
  Future<void> setPlaying({
    String? songId,
    String? title,
    String? artist,
  }) async {}

  @override
  Future<void> markRead(String withUser, int upTo) async {}
  @override
  Future<List<ChatProfile>> profiles() async => people;
  @override
  Future<void> saveProfile({
    required String displayName,
    required String bio,
  }) async {}
  @override
  Future<void> saveAvatar(File image) async {}
  @override
  Uri avatarUri(String user) => Uri.parse('http://a/$user');
}

void main() {
  late Directory dir;
  late _Server server;
  final opened = <MessagesController>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chats');
    server = _Server();
  });
  tearDown(() async {
    await Future.wait(opened.map((chats) => chats.savedForTest()));
    opened.clear();
    await dir.delete(recursive: true);
  });

  MessagesController controller() {
    final chats = MessagesController(
      savedChats: dir,
      inboxPollEvery: const Duration(hours: 1),
      threadPollEvery: const Duration(hours: 1),
      me: () => 'me',
    );
    opened.add(chats);
    return chats;
  }

  test(
    'a chat is there straight away the next time, without a connection',
    () async {
      server.receive('hello');
      final first = controller()..attach(server);
      await first.openThread('sam');
      first.closeThread();
      await first.savedForTest();
      first.dispose();

      server.failure = const MessagingOffline("Can't reach the server.");
      final second = controller()..attach(server);
      await second.openThread('sam');
      expect(second.thread.single.text, 'hello');
      second.dispose();
    },
  );

  test('closing a chat no longer forgets it while the app is open', () async {
    server.receive('hello');
    final chats = controller()..attach(server);
    await chats.openThread('sam');
    chats.closeThread();
    server.failure = const MessagingOffline('down');
    await chats.openThread('sam');
    expect(chats.thread.single.text, 'hello');
    chats.dispose();
  });

  test('older messages load on request and only once', () async {
    for (final text in ['a', 'b', 'c', 'd', 'e']) {
      server.receive(text);
    }
    final chats = controller()..attach(server);
    await chats.openThread('sam');
    expect(chats.thread.map((m) => m.text), ['d', 'e']);
    expect(chats.mayHaveOlder, isTrue);

    await chats.loadOlder();
    expect(chats.thread.map((m) => m.text), ['b', 'c', 'd', 'e']);

    await chats.loadOlder();
    await chats.loadOlder();
    expect(chats.thread.map((m) => m.text), ['a', 'b', 'c', 'd', 'e']);
    expect(chats.mayHaveOlder, isFalse);
    chats.dispose();
  });

  test(
    'a message written offline shows as pending and sends later, once',
    () async {
      final chats = controller()..attach(server);
      await chats.openThread('sam');
      server.failure = const MessagingOffline('down');

      expect(await chats.send(text: 'hi'), isTrue);
      expect(chats.thread.single.text, 'hi');
      expect(chats.thread.single.isPending, isTrue);
      expect(server.messages, isEmpty);

      server.failure = null;
      await chats.flushPending();
      await chats.flushPending();

      expect(server.messages.single.text, 'hi');
      expect(chats.thread.single.isPending, isFalse);
      chats.dispose();
    },
  );

  test('a pending message survives a restart', () async {
    final first = controller()..attach(server);
    await first.openThread('sam');
    server.failure = const MessagingOffline('down');
    await first.send(text: 'hi');
    await first.savedForTest();
    first.dispose();

    server.failure = null;
    final second = controller()..attach(server);
    await second.flushPending();
    expect(server.messages.single.text, 'hi');
    second.dispose();
  });

  test('a message the server refuses is not retried for ever', () async {
    final chats = controller()..attach(server);
    await chats.openThread('sam');
    server.failure = const MessagingException('That was too long.');

    expect(await chats.send(text: 'hi'), isFalse);

    expect(chats.error, 'That was too long.');
    expect(chats.thread, isEmpty);
    chats.dispose();
  });

  test('anything can be sent to anyone, without opening the chat', () async {
    final chats = controller()..attach(server);
    await chats.sendTo('sam', playlistId: 'p1', songTitle: 'Road trip');
    await chats.sendTo('sam', albumId: 'a1', songTitle: 'An album');
    await chats.sendTo('sam', songId: 's1', songTitle: 'A song');

    expect(server.messages.map((m) => m.playlistId), ['p1', null, null]);
    expect(server.messages[1].albumId, 'a1');
    expect(server.messages[2].songId, 's1');
    chats.dispose();
  });

  test('replies and reactions reach the server', () async {
    server.receive('hello');
    final chats = controller()..attach(server);
    await chats.openThread('sam');

    await chats.send(text: 'yes', replyTo: 1);
    expect(server.messages.last.replyTo, 1);

    await chats.react(1, '🔥');
    expect(server.reacted.single, (1, '🔥'));
    expect(chats.thread.first.reactions['me'], '🔥');
    chats.dispose();
  });

  test('signing out forgets saved chats and anything waiting', () async {
    server.receive('hello');
    final chats = controller()..attach(server);
    await chats.openThread('sam');
    await chats.savedForTest();
    expect(dir.listSync(recursive: true), isNotEmpty);

    chats.attach(null);
    await chats.savedForTest();

    expect(chats.thread, isEmpty);
    expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
    chats.dispose();
  });

  test('a new event wakes the inbox without waiting for the timer', () async {
    final chats = MessagesController(
      savedChats: dir,
      inboxPollEvery: const Duration(hours: 1),
      threadPollEvery: const Duration(hours: 1),
      me: () => 'me',
      listenForEvents: true,
    )..attach(server);
    for (var i = 0; i < 100 && server.waits < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(server.waits, greaterThanOrEqualTo(2));
    chats.attach(null);
    chats.dispose();
  });
}
