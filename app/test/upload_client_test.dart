import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/core/upload_client.dart';

void main() {
  late HttpServer server;
  late Directory temp;
  late UploadClient client;
  final received = <String, dynamic>{};
  var reply = (status: 200, body: '{"status":"ok","file":"x/y.mp3"}');

  setUp(() async {
    received.clear();
    reply = (status: 200, body: '{"status":"ok","file":"x/y.mp3"}');
    temp = await Directory.systemTemp.createTemp('yomi_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      received['path'] = request.uri.path;
      received['query'] = request.uri.queryParameters;
      received['contentType'] = request.headers.contentType.toString();
      final bytes = await request.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      received['body'] = bytes;
      request.response
        ..statusCode = reply.status
        ..write(reply.body);
      await request.response.close();
    });
    final auth = SubsonicClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      username: 'keli',
      password: 'pw',
    );
    client = UploadClient(
      serverUrl: 'http://127.0.0.1:${server.port}',
      auth: auth,
      uploadPortOverride: server.port,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  test(
    'sends the file as multipart with token auth and reports full progress',
    () async {
      final file = File('${temp.path}/全ての人の魂の戦い.mp3')
        ..writeAsBytesSync(List.filled(200000, 7));
      final progress = <double>[];

      await client.upload(file, onProgress: progress.add);

      expect(received['path'], '/upload');
      final query = received['query'] as Map<String, String>;
      expect(query['u'], 'keli');
      expect(query['t'], isNotEmpty);
      expect(query.containsKey('p'), isFalse);
      final text = latin1.decode(received['body'] as List<int>);
      expect(text, contains('name="file"'));
      expect(
        utf8.decode(received['body'] as List<int>, allowMalformed: true),
        contains('全ての人の魂の戦い.mp3'),
      );
      expect(
        (received['body'] as List<int>).where((b) => b == 7).length,
        200000,
      );
      expect(progress.last, 1.0);
      expect(progress, orderedEquals([...progress]..sort()));
    },
  );

  test('server rejections surface the server message', () async {
    reply = (
      status: 415,
      body:
          '{"status":"error","message":"file content is not recognised audio"}',
    );
    final file = File('${temp.path}/a.mp3')..writeAsBytesSync([1, 2, 3]);

    await expectLater(
      client.upload(file, onProgress: (_) {}),
      throwsA(
        isA<UploadException>().having(
          (e) => e.message,
          'message',
          contains('not recognised audio'),
        ),
      ),
    );
  });

  test('derives the upload address from the server address', () {
    expect(
      deriveUploadUri('http://100.88.180.104:4533/').toString(),
      'http://100.88.180.104:4534/upload',
    );
    expect(deriveUploadUri('http://192.168.1.18:4533').port, uploadPort);
  });

  test('an unreachable server gives a friendly message', () async {
    await server.close(force: true);
    final file = File('${temp.path}/a.mp3')..writeAsBytesSync([1, 2, 3]);

    await expectLater(
      client.upload(file, onProgress: (_) {}),
      throwsA(
        isA<UploadException>().having(
          (e) => e.message,
          'message',
          contains('Cannot reach'),
        ),
      ),
    );
  });
}
