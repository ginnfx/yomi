import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/connection_probe.dart';
import 'package:yomi/core/listening/history_api.dart';
import 'package:yomi/core/listening/play_history.dart';
import 'package:yomi/core/messaging/messaging_api.dart';
import 'package:yomi/core/offline/outbox.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/assistant_controller.dart';
import 'package:yomi/state/imports_controller.dart';
import 'package:yomi/state/listening_log.dart';
import 'package:yomi/state/messages_controller.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/state/upload_queue.dart';

import 'upload_queue_test.dart' show FakeTransport;

SubsonicClient auth() =>
    SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'p');

class DeferredMessages implements MessagingTransport {
  final reply = Completer<ChatMessage>();
  @override
  Future<List<ChatConversation>> conversations() async => [];
  @override
  Future<List<ChatProfile>> profiles() async => [];
  @override
  Future<ChatMessage> send(
    String to, {
    String text = '',
    String? songId,
    String? songTitle,
    String? albumId,
    String? playlistId,
    int? replyTo,
  }) => reply.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('account-state'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('replica replay retains queued edits without making requests', () async {
    final outbox = Outbox(File('${dir.path}/outbox.json'));
    await outbox.add(const OutboxItem('star', {'id': 'song'}));
    var requests = 0;
    final client = SubsonicClient(
      baseUrl: 'http://s',
      username: 'u',
      password: 'p',
      outbox: outbox,
      isReadOnly: () => true,
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('{"subsonic-response":{"status":"ok"}}', 200);
      }),
    );
    await client.flushOutbox();
    expect(requests, 0);
    expect(outbox.items, hasLength(1));
  });

  test('assistant drops old account history and late answers', () async {
    final response = Completer<http.Response>();
    final assistant = AssistantController(
      index: () => SearchIndex([]),
      taste: () => (topArtists: [], moods: []),
    );
    assistant.attach(
      AiApi(
        serverUrl: 'http://s',
        auth: auth(),
        port: 4534,
        httpClient: MockClient((_) => response.future),
      ),
    );
    final asking = assistant.ask('private question');
    assistant.attach(null);
    response.complete(
      http.Response('{"reply":"private answer","songs":[]}', 200),
    );
    await asking;
    expect(assistant.turns, isEmpty);
    expect(assistant.isThinking, isFalse);
    assistant.dispose();
  });

  test('late failed send cannot resurrect a signed-out message', () async {
    final old = DeferredMessages();
    final messages = MessagesController(
      savedChats: Directory('${dir.path}/chats'),
      me: () => 'old',
    );
    messages.attach(old);
    final sending = messages.sendTo('friend', text: 'private');
    messages.attach(null);
    old.reply.completeError(const MessagingOffline('offline'));
    expect(await sending, isFalse);
    await messages.savedForTest();
    final next = DeferredMessages();
    messages.attach(next);
    await messages.flushPending();
    expect(next.reply.isCompleted, isFalse);
    messages.dispose();
  });

  test(
    'offline import deletions survive restart and replay before pulling',
    () async {
      var down = false;
      final server = <Map<String, dynamic>>[];
      ImportsApi api() => ImportsApi(
        serverUrl: 'http://s',
        auth: auth(),
        port: 4534,
        httpClient: MockClient((request) async {
          if (down) throw http.ClientException('offline');
          if (request.method == 'GET')
            return http.Response(jsonEncode({'imports': server}), 200);
          final id = request.url.pathSegments.last;
          server.removeWhere((p) => p['id'] == id);
          if (request.method == 'PUT')
            server.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }),
      );
      final file = File('${dir.path}/imports.json');
      final imports = ImportsController(file: file);
      await imports.attach(api());
      final playlist = await imports.add('Private', []);
      await pumpEventQueue();
      down = true;
      await imports.remove(playlist.id);
      final restarted = ImportsController(file: file);
      await restarted.load();
      down = false;
      await restarted.attach(api());
      expect(server, isEmpty);
      expect(restarted.playlists, isEmpty);
    },
  );

  test(
    'sign-out forgets queued uploads before another server attaches',
    () async {
      final queue = UploadQueue(
        queueFile: File('${dir.path}/queue.json'),
        hashCacheFile: File('${dir.path}/hashes.json'),
      );
      final file = File('${dir.path}/private.mp3')
        ..writeAsStringSync('private');
      await queue.addFiles([file.path]);
      queue.attach(null);
      final next = FakeTransport();
      queue.attach(next);
      await pumpEventQueue();
      expect(queue.items, isEmpty);
      expect(next.uploaded, isEmpty);
      await queue.save();
      queue.dispose();
    },
  );

  test('late history response cannot enter another account', () async {
    final response = Completer<http.Response>();
    final entered = Completer<void>();
    final history = PlayHistory(File('${dir.path}/history.json'));
    final log = ListeningLog(
      directory: Directory('${dir.path}/logs'),
      history: history,
    );
    final api = HistoryApi(
      serverUrl: 'http://s',
      auth: auth(),
      port: 4534,
      httpClient: MockClient((request) {
        if (!entered.isCompleted) entered.complete();
        return response.future;
      }),
    );
    await log.attach(api, 'old');
    final syncing = log.sync();
    await entered.future;
    await log.attach(null, null);
    await log.attach(api, 'new');
    response.complete(
      http.Response(
        jsonEncode({
          'events': [
            {
              'id': 'old-play',
              'songId': 'secret',
              'artist': 'Old',
              'title': 'Private',
              'atMs': 1,
            },
          ],
          'next': 1,
        }),
        200,
      ),
    );
    await syncing;
    expect(log.events, isEmpty);
    log.dispose();
    history.dispose();
  });

  test('late failover result cannot recreate a signed-out session', () async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'http://away',
      'home_url': 'http://home',
      'username': 'u',
      'password': 'p',
    });
    final response = Completer<ProbeResult>();
    final entered = Completer<void>();
    final session = SessionController(
      httpClient: MockClient(
        (_) async => throw const SocketException('offline'),
      ),
      roleProbe: (_, _) async => false,
      urlProbe: (url, _, _) {
        entered.complete();
        return response.future;
      },
    );
    await session.restoreSaved();
    final checking = session.checkServer();
    await entered.future;
    var unregistered = false;
    session.beforeSignOut = () async => unregistered = true;
    await session.signOut();
    response.complete(
      const ProbeResult(url: 'http://home', isOk: true, elapsed: Duration.zero),
    );
    await checking;
    expect(unregistered, isTrue);
    expect(session.isSignedIn, isFalse);
    expect(session.accountId, isNull);
    session.dispose();
  });
}
