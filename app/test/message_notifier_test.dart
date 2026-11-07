import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/messaging/messaging_api.dart';
import 'package:yomi/core/notifications/message_notifier.dart';
import 'package:yomi/core/notifications/notification_sink.dart';
import 'package:yomi/state/messages_controller.dart';

class _RecordingSink implements NotificationSink {
  final shown = <({String title, String body, String payload})>[];
  var cancelled = 0;

  @override
  Future<void> start({required ValueChanged<String> onTap}) async {}
  @override
  Future<void> askPermission() async {}
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async => shown.add((title: title, body: body, payload: payload));
  @override
  Future<void> cancelAll() async => cancelled++;
}

class _Messages extends MessagesController {
  List<ChatConversation> next = const [];

  @override
  List<ChatConversation> get conversations => next;
  @override
  List<ChatProfile> get people => const [ChatProfile(user: 'sam')];

  void deliver(List<ChatConversation> conversations) {
    next = conversations;
    notifyListeners();
  }
}

ChatConversation _chat({
  required int id,
  String text = 'hi',
  String from = 'sam',
  int unread = 1,
  String? song,
}) => ChatConversation(
  withUser: 'sam',
  unread: unread,
  last: ChatMessage(
    id: id,
    from: from,
    to: from == 'sam' ? 'me' : 'sam',
    text: text,
    sentAt: DateTime(2026),
    songId: song == null ? null : 's1',
    songTitle: song,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Messages messages;
  late _RecordingSink sink;
  var isForeground = false;
  var isEnabled = true;
  late MessageNotifier notifier;

  setUp(() {
    messages = _Messages();
    sink = _RecordingSink();
    isForeground = false;
    isEnabled = true;
    notifier = MessageNotifier(
      messages: messages,
      sink: sink,
      isEnabled: () => isEnabled,
      nameOf: (user) => 'Sam',
      isInForeground: () => isForeground,
    )..start();
  });
  tearDown(() {
    notifier.dispose();
    messages.dispose();
  });

  test('stays quiet about what was already waiting when the app opened', () {
    messages.deliver([_chat(id: 5)]);

    expect(sink.shown, isEmpty);
  });

  test('announces a new message from a friend while the app is away', () {
    messages.deliver([_chat(id: 5)]);

    messages.deliver([_chat(id: 6, text: 'listen to this')]);

    expect(sink.shown.single.title, 'Sam');
    expect(sink.shown.single.body, 'listen to this');
    expect(sink.shown.single.payload, 'sam');
  });

  test('says which song was shared when there is no text', () {
    messages.deliver([_chat(id: 5)]);

    messages.deliver([_chat(id: 6, text: '', song: 'Blue')]);

    expect(sink.shown.single.body, 'Shared "Blue"');
  });

  test('does not notify while the app is open, or when switched off', () {
    messages.deliver([_chat(id: 5)]);

    isForeground = true;
    messages.deliver([_chat(id: 6)]);
    isForeground = false;
    isEnabled = false;
    messages.deliver([_chat(id: 7)]);

    expect(sink.shown, isEmpty);
  });

  test('never notifies about your own messages or read chats', () {
    messages.deliver([_chat(id: 5)]);

    messages.deliver([_chat(id: 6, from: 'me', unread: 0)]);
    messages.deliver([_chat(id: 7, unread: 0)]);

    expect(sink.shown, isEmpty);
  });

  test('counts several unread messages in the title', () {
    messages.deliver([_chat(id: 5)]);

    messages.deliver([_chat(id: 8, unread: 3)]);

    expect(sink.shown.single.title, 'Sam · 3 new messages');
  });
}
