import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/messaging/messaging_api.dart';
import 'package:yomi/state/messages_controller.dart';
import 'package:yomi/ui/pages/messages_page.dart';

import 'support/screen_harness.dart';

class FakeTransport implements MessagingTransport {
  @override
  Future<void> saveTaste({
    required List<String> topArtists,
    required List<String> topMoods,
  }) async {}

  @override
  Future<void> react(int messageId, String emoji) async {}
  @override
  Future<int> waitForChange(int revision) async => revision;
  @override
  Future<void> setPlaying({
    String? songId,
    String? title,
    String? artist,
  }) async {}

  final List<ChatMessage> messages = [];
  List<ChatProfile> people = const [
    ChatProfile(user: 'demo'),
    ChatProfile(user: 'sam', displayName: 'Sam', bio: 'Mostly jazz'),
  ];
  Exception? failure;
  final List<int> readUpTo = [];
  int nextId = 1;
  String? savedName;
  File? savedAvatar;

  void receive(String text) => messages.add(
    ChatMessage(
      id: nextId++,
      from: 'sam',
      to: 'demo',
      text: text,
      sentAt: DateTime(2026),
    ),
  );

  @override
  Future<List<ChatConversation>> conversations() async {
    final error = failure;
    if (error != null) throw error;
    if (messages.isEmpty) return const [];
    return [
      ChatConversation(
        withUser: 'sam',
        last: messages.last,
        unread: messages
            .where((m) => m.from == 'sam' && !readUpTo.any((r) => r >= m.id))
            .length,
      ),
    ];
  }

  @override
  Future<List<ChatMessage>> thread(
    String withUser, {
    int after = 0,
    int before = 0,
  }) async {
    final error = failure;
    if (error != null) throw error;
    return messages.where((m) => m.id > after).toList();
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
      from: 'demo',
      to: to,
      text: text,
      sentAt: DateTime(2026),
      songId: songId,
      songTitle: songTitle,
    );
    messages.add(message);
    return message;
  }

  @override
  Future<void> markRead(String withUser, int upTo) async => readUpTo.add(upTo);

  @override
  Future<List<ChatProfile>> profiles() async => people;

  @override
  Future<void> saveProfile({
    required String displayName,
    required String bio,
  }) async {
    final error = failure;
    if (error != null) throw error;
    savedName = displayName;
  }

  @override
  Future<void> saveAvatar(File image) async => savedAvatar = image;

  @override
  Uri avatarUri(String user, {int version = 0}) =>
      Uri.parse('http://server/$user');

  @override
  Uri bannerUri(String user, {int version = 0}) =>
      Uri.parse('http://server/$user/banner');

  @override
  Future<void> saveBanner(File image) async {}

  @override
  Future<List<int>?> fetchImage(Uri uri) async => null;
}

void main() {
  setUpAll(loadAppFonts);

  group('MessagesController', () {
    late FakeTransport transport;
    late MessagesController controller;

    setUp(() {
      transport = FakeTransport();
      controller = MessagesController(
        inboxPollEvery: const Duration(hours: 1),
        threadPollEvery: const Duration(hours: 1),
      );
    });
    tearDown(() => controller.dispose());

    Future<void> attached() async {
      controller.attach(transport);
      await controller.refresh();
      await Future<void>.delayed(Duration.zero);
    }

    test('counts unread messages across conversations', () async {
      transport.receive('one');
      transport.receive('two');
      await attached();
      expect(controller.unreadTotal, 2);
      expect(controller.profileOf('sam').name, 'Sam');
      expect(controller.profileOf('new').name, 'new');
    });

    test('opening a thread loads it and marks it read', () async {
      transport.receive('hello');
      await attached();
      await controller.openThread('sam');
      expect(controller.thread.single.text, 'hello');
      expect(transport.readUpTo, [1]);
    });

    test('a sent message appears once, even if a poll also finds it', () async {
      await attached();
      await controller.openThread('sam');
      expect(await controller.send(text: 'hi'), isTrue);
      await controller.openThread('sam');
      expect(controller.thread.map((m) => m.text), ['hi']);
    });

    test(
      'a message from a friend is not lost when sending right after it',
      () async {
        await attached();
        await controller.openThread('sam');
        transport.receive('from sam, not polled yet');
        await controller.send(text: 'from me');
        await controller.pollThreadForTest();
        expect(controller.thread.map((m) => m.text), [
          'from sam, not polled yet',
          'from me',
        ]);
      },
    );

    test('a failed send reports why and returns false', () async {
      await attached();
      await controller.openThread('sam');
      transport.failure = const MessagingException('Too many messages');
      expect(await controller.send(text: 'hi'), isFalse);
      expect(controller.error, 'Too many messages');
    });

    test('a failed poll keeps what is on screen', () async {
      transport.receive('kept');
      await attached();
      transport.failure = const MessagingException("Can't reach the server.");
      await controller.refresh();
      expect(controller.conversations, hasLength(1));
      expect(controller.isAvailable, isTrue);
    });

    test('the backup server turns messages off, and back on after', () async {
      await attached();
      transport.failure = const MessagingUnavailable();
      await controller.refresh();
      expect(controller.isAvailable, isFalse);
      transport.failure = null;
      await controller.refresh();
      expect(controller.isAvailable, isTrue);
    });

    test('publishes the profile so others can find this user', () async {
      await attached();
      final avatar = File('a.jpg');
      await controller.publishProfile(
        displayName: 'Demo',
        bio: '',
        avatar: avatar,
      );
      expect(transport.savedName, 'Demo');
      expect(transport.savedAvatar, avatar);
    });

    test('signing out clears everything', () async {
      transport.receive('private');
      await attached();
      controller.attach(null);
      expect(controller.conversations, isEmpty);
      expect(controller.people, isEmpty);
    });
  });

  group('screens', () {
    late FakeTransport transport;
    late MessagesController controller;

    Widget wrap(Widget child) =>
        ChangeNotifierProvider<MessagesController>.value(
          value: controller,
          child: child,
        );

    setUp(() {
      transport = FakeTransport();
      controller = MessagesController(
        inboxPollEvery: const Duration(hours: 1),
        threadPollEvery: const Duration(hours: 1),
      );
    });
    tearDown(() => controller.dispose());

    testWidgets('the list says who can be messaged and what is private', (
      tester,
    ) async {
      await tester.runAsync(() async {
        controller.attach(transport);
        await controller.refresh();
      });
      await pumpScreen(tester, wrap(const MessagesPage()), size: phoneSize);
      // Once in the friends row, once in the list. You never appear yourself.
      expect(find.text('Sam'), findsNWidgets(2));
      expect(find.text('demo'), findsNothing);
      expect(find.textContaining('end-to-end'), findsOneWidget);
    });

    testWidgets('the backup server shows an explanation', (tester) async {
      transport.failure = const MessagingUnavailable();
      await tester.runAsync(() async {
        controller.attach(transport);
        await controller.refresh();
      });
      await pumpScreen(tester, wrap(const MessagesPage()), size: phoneSize);
      expect(find.textContaining('backup server'), findsOneWidget);
    });

    testWidgets('sending clears the box, a failure keeps the text', (
      tester,
    ) async {
      await tester.runAsync(() async {
        controller.attach(transport);
        await controller.refresh();
      });
      await pumpScreen(
        tester,
        wrap(const ThreadPage(user: 'sam')),
        size: phoneSize,
      );
      await tester.enterText(find.byType(TextField), 'first');
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settleScreen(tester);
      expect(find.text('first'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );

      transport.failure = const MessagingException('Nope');
      await tester.enterText(find.byType(TextField), 'second');
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settleScreen(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'second',
      );
      expect(find.text('Nope'), findsOneWidget);
    });
  });
}
