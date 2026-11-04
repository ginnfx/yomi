import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/core/upload/bulk_upload_api.dart';

void main() {
  late HttpServer server;
  late Directory temp;
  late BulkUploadApi api;
  late File file;
  var reply = (status: 200, body: '{}', retryAfter: null as String?);
  Uri? lastUri;
  List<int> lastBody = const [];
  String? lastLength;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bulk_api');
    file = File('${temp.path}/song.mp3')
      ..writeAsBytesSync(List.filled(1000, 7));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      lastUri = request.uri;
      lastLength = request.headers.value(HttpHeaders.contentLengthHeader);
      lastBody = await request.expand((chunk) => chunk).toList();
      request.response.statusCode = reply.status;
      if (reply.retryAfter != null) {
        request.response.headers.set(
          HttpHeaders.retryAfterHeader,
          reply.retryAfter!,
        );
      }
      request.response.write(reply.body);
      await request.response.close();
    });
    api = BulkUploadApi(
      serverUrl: 'http://127.0.0.1:1234/',
      auth: SubsonicClient(
        baseUrl: 'http://127.0.0.1',
        username: 'keli',
        password: 'secret',
      ),
      port: server.port,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  Future<PutResult> put() =>
      api.put(file, sha256: 'abc', name: 'My Song?.mp3', onProgress: (_) {});

  test('check sends hashes and returns the known ones', () async {
    reply = (status: 200, body: '{"known":["a"]}', retryAfter: null);
    final known = await api.check(['a', 'b']);
    expect(known, {'a'});
    expect(lastUri!.path, '/v1/check');
    expect(lastUri!.queryParameters['u'], 'keli');
    expect(jsonDecode(utf8.decode(lastBody)), {
      'hashes': ['a', 'b'],
    });
  });

  test('put streams the file with its length and escaped name', () async {
    reply = (status: 201, body: '{"status":"ok"}', retryAfter: null);
    final seen = <double>[];
    final result = await api.put(
      file,
      sha256: 'abc',
      name: 'My Song?.mp3',
      onProgress: seen.add,
    );
    expect(result, PutResult.stored);
    expect(lastUri!.path, '/v1/upload/abc');
    expect(lastUri!.queryParameters['name'], 'My Song?.mp3');
    expect(lastLength, '1000');
    expect(lastBody, hasLength(1000));
    expect(seen.last, 1);
  });

  test('put reports when the server already had the song', () async {
    reply = (status: 200, body: '{"status":"duplicate"}', retryAfter: null);
    expect(await put(), PutResult.duplicate);
  });

  test('a busy server says how long to wait', () async {
    reply = (status: 429, body: '{}', retryAfter: '7');
    await expectLater(
      put(),
      throwsA(
        isA<UploadRetryLater>().having(
          (e) => e.after,
          'after',
          const Duration(seconds: 7),
        ),
      ),
    );
  });

  test('each server answer maps to the right outcome', () async {
    final cases = <int, Matcher>{
      404: isA<UploadRouteMissing>(),
      401: isA<UploadAuthFailed>(),
      507: isA<UploadStorageFull>(),
      422: isA<UploadCorrupted>(),
      502: isA<UploadUnreachable>(),
      415: isA<UploadRejected>(),
    };
    for (final entry in cases.entries) {
      reply = (status: entry.key, body: '{"message":"nope"}', retryAfter: null);
      await expectLater(put(), throwsA(entry.value), reason: '${entry.key}');
    }
  });

  test('a refusal carries the server message, or a plain fallback', () async {
    reply = (status: 415, body: '{"message":"not audio"}', retryAfter: null);
    await expectLater(put(), throwsA(predicate((e) => '$e' == 'not audio')));
    reply = (status: 418, body: 'teapot', retryAfter: null);
    await expectLater(
      put(),
      throwsA(predicate((e) => '$e' == 'Upload failed (HTTP 418).')),
    );
  });

  test('a dead server counts as unreachable', () async {
    await server.close(force: true);
    await expectLater(put(), throwsA(isA<UploadUnreachable>()));
    await expectLater(api.check(['a']), throwsA(isA<UploadUnreachable>()));
  });
}
