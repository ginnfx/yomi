import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/youtube/process_yt_dlp.dart';
import 'package:yomi/core/youtube/yt_dlp.dart';

/// Stands in for yt-dlp: prints a progress line and its arguments, or fails.
const _script = '''#!/bin/sh
if [ "\$1" = "fail" ]; then echo "ERROR: Video unavailable" >&2; exit 1; fi
echo "download: 50.0%"
echo "args: \$*"
''';

void main() {
  late Directory dir;
  var downloads = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yomi_ytdlp');
    downloads = 0;
  });
  tearDown(() => dir.delete(recursive: true));

  ProcessYtDlp ytDlp({String? listedHash}) {
    final bytes = utf8.encode(_script);
    final hash = listedHash ?? sha256.convert(bytes).toString();
    return ProcessYtDlp(
      directory: dir,
      binaryName: 'yt-dlp_test',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('SHA2-256SUMS')) {
          return http.Response('$hash  yt-dlp_test\nffff  other\n', 200);
        }
        downloads++;
        return http.Response.bytes(bytes, 200);
      }),
    );
  }

  test(
    'installs the binary once, then runs it and streams its lines',
    () async {
      // Arrange
      final runner = ytDlp();
      final lines = <String>[];

      // Act
      await runner.run(['first']);
      final out = await runner.run(['second', 'x'], onLine: lines.add);

      // Assert
      expect(downloads, 1);
      expect(out, contains('args: second x'));
      expect(lines.first, 'download: 50.0%');
    },
  );

  test(
    'refuses a download that does not match the published checksum',
    () async {
      // Arrange
      final runner = ytDlp(listedHash: 'a' * 64);

      // Act / Assert
      await expectLater(runner.run(['x']), throwsA(isA<YtDlpException>()));
      expect(File('${dir.path}/yt-dlp_test').existsSync(), isFalse);
    },
  );

  test("a failure reports yt-dlp's own last error line", () async {
    // Arrange
    final runner = ytDlp();

    // Act / Assert
    await expectLater(
      runner.run(['fail']),
      throwsA(
        isA<YtDlpException>().having(
          (e) => e.message,
          'message',
          'ERROR: Video unavailable',
        ),
      ),
    );
  });

  test('picks the official binary for each desktop', () {
    expect(ProcessYtDlp.binaryFor('macos'), 'yt-dlp_macos');
    expect(ProcessYtDlp.binaryFor('linux'), 'yt-dlp_linux');
    expect(ProcessYtDlp.binaryFor('ios'), isNull);
  });
}
