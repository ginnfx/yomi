import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/messaging/messaging_api.dart';
import 'package:yomi/state/messages_controller.dart';

class _Transport implements MessagingTransport {
  final sent = <String>[];

  @override
  Future<List<ChatConversation>> conversations() async => [];
  @override
  Future<List<ChatProfile>> profiles() async => [];
  @override
  Future<List<ChatMessage>> thread(
    String user, {
    int after = 0,
    int before = 0,
  }) async => [];
  @override
  Future<ChatMessage> send(
    String user, {
    String text = '',
    String? songId,
    String? songTitle,
    String? albumId,
    String? playlistId,
    int? replyTo,
  }) async {
    sent.add(text);
    return ChatMessage(
      id: 1,
      from: 'new',
      to: user,
      text: text,
      sentAt: DateTime(2026),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  setUp(
    () => dir = Directory.systemTemp.createTempSync('message-account-disk'),
  );
  tearDown(() => dir.deleteSync(recursive: true));

  final privateDraft = ChatMessage(
    id: -1,
    from: 'old',
    to: 'friend',
    text: 'private old draft',
    sentAt: DateTime(2026),
    isPending: true,
  );

  test(
    'pending read started before logout cannot restore old drafts',
    () async {
      final contents = jsonEncode([privateDraft.toJson()]);
      File('${dir.path}/pending.json').writeAsStringSync(contents);
      final entered = Completer<void>();
      final read = Completer<String>();
      final messages = MessagesController(
        savedChats: dir,
        readSavedFile: (_) {
          entered.complete();
          return read.future;
        },
      );
      messages.attach(_Transport());
      await entered.future;
      messages.attach(null);
      final next = _Transport();
      messages.attach(next);
      read.complete(contents);
      await messages.savedForTest();
      await messages.flushPending();
      expect(next.sent, isEmpty);
      expect(messages.thread, isEmpty);
      messages.dispose();
    },
  );

  test(
    'same friend opened by next account rejects old saved thread read',
    () async {
      final name = base64Url.encode(utf8.encode('friend'));
      final contents = jsonEncode([
        ChatMessage(
          id: 1,
          from: 'friend',
          to: 'old',
          text: 'private old chat',
          sentAt: DateTime(2026),
        ).toJson(),
      ]);
      File('${dir.path}/thread-$name.json').writeAsStringSync(contents);
      final entered = Completer<void>();
      final read = Completer<String>();
      final messages = MessagesController(
        savedChats: dir,
        readSavedFile: (_) {
          entered.complete();
          return read.future;
        },
      );
      messages.attach(_Transport());
      final oldOpen = messages.openThread('friend');
      await entered.future;
      messages.attach(null);
      messages.attach(_Transport());
      await messages.openThread('friend');
      read.complete(contents);
      await oldOpen;
      expect(messages.thread, isEmpty);
      messages.dispose();
    },
  );
}
