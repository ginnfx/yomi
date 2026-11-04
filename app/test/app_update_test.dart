import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/app_update.dart';

Map<String, dynamic> releaseJson({
  String tag = 'v1.2.3',
  String body = 'Fixes',
  List<String> assets = const [
    'Yomi-android.apk',
    'Yomi-android.apk.sha256',
    'Yomi-macOS.zip',
  ],
  String assetBase = 'https://github.com/ginnfx/yomi/releases/download/v1.2.3',
}) => {
  'tag_name': tag,
  'body': body,
  'html_url': 'https://github.com/ginnfx/yomi/releases/tag/$tag',
  'assets': [
    for (final name in assets)
      {'name': name, 'browser_download_url': '$assetBase/$name'},
  ],
};

void main() {
  group('AppVersion', () {
    test('parses versions with an optional v prefix and build number', () {
      expect(AppVersion.tryParse('v1.2.3').toString(), '1.2.3');
      expect(AppVersion.tryParse('1.2.3+45').toString(), '1.2.3');
    });

    test('rejects anything that is not a plain release version', () {
      for (final bad in ['', '1.2', '1.2.3-beta', 'abc', '1.2.x', 'v']) {
        expect(AppVersion.tryParse(bad), isNull, reason: bad);
      }
    });

    test('compares numerically rather than as text', () {
      final older = AppVersion.tryParse('1.9.0')!;
      final newer = AppVersion.tryParse('1.10.0')!;

      expect(newer.isNewerThan(older), isTrue);
      expect(older.isNewerThan(newer), isFalse);
      expect(older.isNewerThan(older), isFalse);
    });
  });

  group('ReleaseInfo', () {
    test('reads version, notes, page and asset links', () {
      final release = ReleaseInfo.tryParse(releaseJson())!;

      expect(release.version.toString(), '1.2.3');
      expect(release.notes, 'Fixes');
      expect(release.pageUrl.path, '/ginnfx/yomi/releases/tag/v1.2.3');
      expect(release.apkUrl!.path, endsWith('/Yomi-android.apk'));
      expect(release.checksumUrl!.path, endsWith('/Yomi-android.apk.sha256'));
    });

    test('has no installable APK when the checksum asset is missing', () {
      final release = ReleaseInfo.tryParse(
        releaseJson(assets: ['Yomi-android.apk']),
      )!;

      expect(release.canInstallApk, isFalse);
    });

    test('ignores assets hosted outside this repository', () {
      final release = ReleaseInfo.tryParse(
        releaseJson(assetBase: 'https://evil.example/ginnfx/yomi/releases'),
      )!;

      expect(release.apkUrl, isNull);
      expect(release.canInstallApk, isFalse);
    });

    test('ignores insecure asset links', () {
      final release = ReleaseInfo.tryParse(
        releaseJson(
          assetBase: 'http://github.com/ginnfx/yomi/releases/download/v1.2.3',
        ),
      )!;

      expect(release.canInstallApk, isFalse);
    });

    test('ignores links that try to escape this repository', () {
      const prefix = 'https://github.com/ginnfx/yomi/releases';
      for (final base in [
        '$prefix/../../evil',
        '$prefix/%2e%2e/%2e%2e/evil',
        '$prefix/download%2f..%2f..%2fevil',
        'https://user@github.com/ginnfx/yomi/releases/download',
        'https://github.com:8443/ginnfx/yomi/releases/download',
      ]) {
        final release = ReleaseInfo.tryParse(releaseJson(assetBase: base))!;
        expect(release.apkUrl, isNull, reason: base);
      }
    });

    test('returns null for malformed release data', () {
      expect(ReleaseInfo.tryParse({}), isNull);
      expect(ReleaseInfo.tryParse({'tag_name': 'nightly'}), isNull);
      expect(ReleaseInfo.tryParse(releaseJson()..remove('html_url')), isNull);
      expect(
        ReleaseInfo.tryParse(releaseJson()..['html_url'] = 'https://evil.example/x'),
        isNull,
      );
    });

    test('caps very long notes', () {
      final release = ReleaseInfo.tryParse(releaseJson(body: 'x' * 50000))!;

      expect(release.notes.length, lessThanOrEqualTo(kMaxReleaseNotesLength));
    });

    test('round trips through toJson for the on-device cache', () {
      final release = ReleaseInfo.tryParse(releaseJson())!;
      final again = ReleaseInfo.tryParse(
        jsonDecode(jsonEncode(release.toJson())) as Map<String, dynamic>,
      )!;

      expect(again.version.toString(), '1.2.3');
      expect(again.notes, release.notes);
      expect(again.apkUrl, release.apkUrl);
      expect(again.checksumUrl, release.checksumUrl);
    });
  });

  group('UpdateClient.fetchLatest', () {
    test('asks GitHub for the latest release of this repository', () async {
      late http.Request seen;
      final client = UpdateClient(
        client: MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode(releaseJson()), 200);
        }),
      );

      final release = await client.fetchLatest();

      expect(release.version.toString(), '1.2.3');
      expect(
        seen.url.toString(),
        'https://api.github.com/repos/ginnfx/yomi/releases/latest',
      );
      expect(seen.headers['User-Agent'], isNotEmpty);
    });

    test('throws when GitHub refuses, so the check can retry later', () async {
      final client = UpdateClient(
        client: MockClient((_) async => http.Response('rate limited', 403)),
      );

      await expectLater(client.fetchLatest(), throwsA(isA<UpdateException>()));
    });

    test('throws on a body that is not valid JSON', () async {
      final client = UpdateClient(
        client: MockClient((_) async => http.Response('<html>', 200)),
      );

      await expectLater(client.fetchLatest(), throwsA(isA<UpdateException>()));
    });

    test('throws on a JSON body that is not a release', () async {
      final client = UpdateClient(
        client: MockClient((_) async => http.Response('[1, 2]', 200)),
      );

      await expectLater(client.fetchLatest(), throwsA(isA<UpdateException>()));
    });
  });

  group('UpdateClient.fetchChecksum', () {
    final uri = Uri.parse('https://github.com/x.sha256');
    final hash = 'a' * 64;

    test('reads the hash from sha256sum style output', () async {
      final client = UpdateClient(
        client: MockClient(
          (_) async => http.Response('$hash  Yomi-android.apk\n', 200),
        ),
      );

      expect(await client.fetchChecksum(uri), hash);
    });

    test('normalises upper-case hashes', () async {
      final client = UpdateClient(
        client: MockClient((_) async => http.Response('A' * 64, 200)),
      );

      expect(await client.fetchChecksum(uri), hash);
    });

    test('rejects anything that is not a SHA-256 hash', () async {
      for (final bad in ['', 'nope', 'a' * 63, 'g' * 64]) {
        final client = UpdateClient(
          client: MockClient((_) async => http.Response(bad, 200)),
        );
        await expectLater(
          client.fetchChecksum(uri),
          throwsA(isA<UpdateException>()),
          reason: bad,
        );
      }
    });
  });

  group('UpdateClient.downloadVerified', () {
    late Directory dir;
    final uri = Uri.parse('https://github.com/x.apk');
    final bytes = utf8.encode('fake apk bytes');
    final goodHash = sha256.convert(bytes).toString();

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('yomi_update_test');
    });
    tearDown(() => dir.delete(recursive: true));

    File target() => File('${dir.path}/Yomi-1.2.3.apk');

    UpdateClient serving(List<int> body, {void Function()? onRequest}) {
      return UpdateClient(
        client: MockClient.streaming((_, _) async {
          onRequest?.call();
          return http.StreamedResponse(
            Stream.value(body),
            200,
            contentLength: body.length,
          );
        }),
      );
    }

    test('saves the file when the checksum matches and reports progress', () async {
      final progress = <double?>[];

      final file = await serving(bytes).downloadVerified(
        uri,
        expectedSha256: goodHash,
        destination: target(),
        onProgress: progress.add,
      );

      expect(await file.readAsBytes(), bytes);
      expect(progress.last, 1.0);
    });

    test('refuses and removes a file whose checksum does not match', () async {
      await expectLater(
        serving(bytes).downloadVerified(
          uri,
          expectedSha256: 'b' * 64,
          destination: target(),
        ),
        throwsA(isA<UpdateException>()),
      );

      expect(await dir.list().toList(), isEmpty);
    });

    test('reuses an already verified file without downloading again', () async {
      await target().writeAsBytes(bytes);
      var requests = 0;

      await serving(bytes, onRequest: () => requests++).downloadVerified(
        uri,
        expectedSha256: goodHash,
        destination: target(),
      );

      expect(requests, 0);
    });

    test('replaces an existing file that fails verification', () async {
      await target().writeAsBytes(utf8.encode('corrupt'));

      final file = await serving(bytes).downloadVerified(
        uri,
        expectedSha256: goodHash,
        destination: target(),
      );

      expect(await file.readAsBytes(), bytes);
    });

    test('fails on an HTTP error and leaves nothing behind', () async {
      final client = UpdateClient(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(const Stream.empty(), 404),
        ),
      );

      await expectLater(
        client.downloadVerified(
          uri,
          expectedSha256: goodHash,
          destination: target(),
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(await dir.list().toList(), isEmpty);
    });

    test('aborts a download larger than the size limit', () async {
      final client = UpdateClient(
        maxDownloadBytes: 4,
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(Stream.value(bytes), 200),
        ),
      );

      await expectLater(
        client.downloadVerified(
          uri,
          expectedSha256: goodHash,
          destination: target(),
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(await dir.list().toList(), isEmpty);
    });

    test('fails when the connection drops partway through', () async {
      final client = UpdateClient(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.fromFuture(
              Future<List<int>>.error(const SocketException('gone')),
            ),
            200,
          ),
        ),
      );

      await expectLater(
        client.downloadVerified(
          uri,
          expectedSha256: goodHash,
          destination: target(),
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(await dir.list().toList(), isEmpty);
    });
  });
}
