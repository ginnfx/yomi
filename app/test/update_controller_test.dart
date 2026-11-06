import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/app_update.dart';
import 'package:yomi/state/update_controller.dart';

final apkBytes = utf8.encode('apk');
final apkHash = sha256.convert(apkBytes).toString();

Map<String, dynamic> release(String version, {bool withChecksum = true}) {
  final base = 'https://github.com/ginnfx/yomi/releases/download/v$version';
  return {
    'tag_name': 'v$version',
    'body': 'Notes for $version',
    'html_url': 'https://github.com/ginnfx/yomi/releases/tag/v$version',
    'assets': [
      {
        'name': 'Yomi-android.apk',
        'browser_download_url': '$base/Yomi-android.apk',
      },
      if (withChecksum)
        {
          'name': 'Yomi-android.apk.sha256',
          'browser_download_url': '$base/Yomi-android.apk.sha256',
        },
    ],
  };
}

class Harness {
  Harness({this.latest, this.mode = UpdateMode.androidInstall});

  Map<String, dynamic>? latest;
  UpdateMode mode;
  int apiCalls = 0;
  bool isApiDown = false;
  String checksum = apkHash;
  DateTime now = DateTime(2026, 11, 4, 12);
  final installed = <File>[];
  final opened = <Uri>[];
  Object? installError;
  late Directory dir;

  Future<UpdateController> build({String current = '1.0.1'}) async {
    dir = await Directory.systemTemp.createTemp('yomi_update_controller');
    addTearDown(() => dir.delete(recursive: true));
    return controller(current: current);
  }

  Future<UpdateController> controller({String current = '1.0.1'}) async {
    final client = UpdateClient(
      client: MockClient.streaming((request, _) async {
        final path = request.url.path;
        if (path.endsWith('/releases/latest')) {
          apiCalls++;
          if (isApiDown) throw const SocketException('down');
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(latest))),
            200,
          );
        }
        final body = path.endsWith('.sha256')
            ? utf8.encode(checksum)
            : apkBytes;
        return http.StreamedResponse(Stream.value(body), 200);
      }),
    );
    return UpdateController(
      currentVersion: AppVersion.tryParse(current)!,
      mode: mode,
      client: client,
      prefs: await SharedPreferences.getInstance(),
      downloadDir: dir,
      install: (file) async {
        if (installError != null) throw installError!;
        installed.add(file);
      },
      openPage: (uri) async => opened.add(uri),
      now: () => now,
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('offers a newer release', () async {
    final h = Harness(latest: release('1.0.2'));
    final c = await h.build();

    await c.check();

    expect(c.phase, UpdatePhase.available);
    expect(c.release!.version.toString(), '1.0.2');
  });

  test('stays quiet when already on the latest version', () async {
    final h = Harness(latest: release('1.0.1'));
    final c = await h.build();

    await c.check();

    expect(c.phase, UpdatePhase.idle);
  });

  test('stays quiet when running a newer build than the release', () async {
    final h = Harness(latest: release('1.0.0'));
    final c = await h.build();

    await c.check();

    expect(c.phase, UpdatePhase.idle);
  });

  test('never offers an Android update without a checksum', () async {
    final h = Harness(latest: release('1.0.2', withChecksum: false));
    final c = await h.build();

    await c.check();

    expect(c.phase, UpdatePhase.idle);
  });

  test('release-page fallback does not require an APK checksum', () async {
    final h = Harness(
      latest: release('1.0.2', withChecksum: false),
      mode: UpdateMode.openReleasePage,
    );
    final c = await h.build();

    await c.check();

    expect(c.phase, UpdatePhase.available);
  });

  test('does not contact GitHub at all when updates are disabled', () async {
    final h = Harness(latest: release('1.0.2'), mode: UpdateMode.disabled);
    final c = await h.build();

    await c.check();

    expect(h.apiCalls, 0);
    expect(c.phase, UpdatePhase.idle);
  });

  group('throttling', () {
    test('checks GitHub at most once every six hours', () async {
      final h = Harness(latest: release('1.0.1'));
      final c = await h.build();

      await c.check();
      h.now = h.now.add(const Duration(hours: 5, minutes: 59));
      await c.check();
      expect(h.apiCalls, 1);

      h.now = h.now.add(const Duration(minutes: 2));
      await c.check();
      expect(h.apiCalls, 2);
    });

    test(
      'still shows a known update after a relaunch inside the window',
      () async {
        final h = Harness(latest: release('1.0.2'));
        await (await h.build()).check();

        final relaunched = await h.controller();
        await relaunched.check();

        expect(h.apiCalls, 1);
        expect(relaunched.phase, UpdatePhase.available);
      },
    );

    test(
      'does not offer the cached release once it has been installed',
      () async {
        final h = Harness(latest: release('1.0.2'));
        await (await h.build()).check();

        final updated = await h.controller(current: '1.0.2');
        await updated.check();

        expect(updated.phase, UpdatePhase.idle);
      },
    );

    test('retries on the next check after a failure', () async {
      final h = Harness(latest: release('1.0.2'))..isApiDown = true;
      final c = await h.build();

      await c.check();
      expect(c.phase, UpdatePhase.idle);

      h.isApiDown = false;
      await c.check();
      expect(h.apiCalls, 2);
      expect(c.phase, UpdatePhase.available);
    });

    test('ignores a corrupt cached release', () async {
      SharedPreferences.setMockInitialValues({
        'update.lastCheckMs': DateTime(2026, 11, 4, 11).millisecondsSinceEpoch,
        'update.latest': 'not json',
      });
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();

      await c.check();

      expect(c.phase, UpdatePhase.idle);
    });
  });

  group('check now', () {
    test('asks GitHub even right after an automatic check', () async {
      // Arrange
      final h = Harness(latest: release('1.0.1'));
      final c = await h.build();
      await c.check();

      // Act
      final result = await c.checkNow();

      // Assert
      expect(h.apiCalls, 2);
      expect(result, UpdateCheckResult.upToDate);
    });

    test('offers a version that was dismissed earlier', () async {
      // Arrange
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();
      await c.check();
      await c.dismiss();

      // Act
      final result = await c.checkNow();

      // Assert
      expect(result, UpdateCheckResult.available);
      expect(c.phase, UpdatePhase.available);
    });

    test('reports a failed check instead of staying quiet', () async {
      // Arrange
      final h = Harness(latest: release('1.0.2'))..isApiDown = true;
      final c = await h.build();

      // Act
      final result = await c.checkNow();

      // Assert
      expect(result, UpdateCheckResult.failed);
      expect(c.phase, UpdatePhase.idle);
    });

    test('never contacts GitHub when updates are disabled', () async {
      // Arrange
      final h = Harness(latest: release('1.0.2'), mode: UpdateMode.disabled);
      final c = await h.build();

      // Act
      final result = await c.checkNow();

      // Assert
      expect(result, UpdateCheckResult.unsupported);
      expect(h.apiCalls, 0);
    });

    test('a check during a download leaves it alone', () async {
      // Arrange
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();
      await c.check();
      final download = c.startUpdate();

      // Act
      final result = await c.checkNow();
      await download;

      // Assert
      expect(result, UpdateCheckResult.available);
      expect(h.installed, hasLength(1));
    });
  });

  group('dismiss', () {
    test('hides that version across relaunches', () async {
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();
      await c.check();

      await c.dismiss();
      expect(c.phase, UpdatePhase.idle);

      final relaunched = await h.controller();
      await relaunched.check();
      expect(relaunched.phase, UpdatePhase.idle);
    });

    test('a newer version appears again after a dismissal', () async {
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();
      await c.check();
      await c.dismiss();

      h.latest = release('1.0.3');
      h.now = h.now.add(const Duration(hours: 7));
      await c.check();

      expect(c.phase, UpdatePhase.available);
      expect(c.release!.version.toString(), '1.0.3');
    });
  });

  group('desktop install', () {
    for (final entry in {
      UpdateMode.macosInstall: kMacAssetName,
      UpdateMode.linuxAppImageInstall: kLinuxAppImageAssetName,
    }.entries) {
      Map<String, dynamic> desktopRelease({bool checksum = true}) {
        final json = release('1.0.2');
        final base = 'https://github.com/ginnfx/yomi/releases/download/v1.0.2';
        (json['assets'] as List).addAll(<Map<String, String>>[
          {'name': entry.value, 'browser_download_url': '$base/${entry.value}'},
          if (checksum)
            {
              'name': '${entry.value}.sha256',
              'browser_download_url': '$base/${entry.value}.sha256',
            },
        ]);
        return json;
      }

      test(
        '${entry.key} downloads its own verified package from cached metadata',
        () async {
          final h = Harness(latest: desktopRelease(), mode: entry.key);
          await (await h.build()).check();
          final c = await h.controller();
          await c.check();
          await c.startUpdate();
          expect(h.apiCalls, 1);
          expect(h.opened, isEmpty);
          expect(
            h.installed.single.path,
            endsWith('Yomi-1.0.2${entry.value.substring(4)}'),
          );
          expect(await h.installed.single.readAsBytes(), apkBytes);
          expect(c.phase, UpdatePhase.readyToInstall);
        },
      );

      test('${entry.key} requires its own checksum', () async {
        final h = Harness(
          latest: desktopRelease(checksum: false),
          mode: entry.key,
        );
        final c = await h.build();
        await c.check();
        expect(c.phase, UpdatePhase.idle);
        expect(h.installed, isEmpty);
      });

      test('${entry.key} rejects a corrupt desktop download', () async {
        final h = Harness(latest: desktopRelease(), mode: entry.key)
          ..checksum = 'b' * 64;
        final c = await h.build();
        await c.check();
        await c.startUpdate();
        expect(c.phase, UpdatePhase.failed);
        expect(h.installed, isEmpty);
      });
    }
  });

  group('Android install', () {
    test('downloads, verifies, then launches the installer', () async {
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();
      await c.check();

      await c.startUpdate();

      expect(c.phase, UpdatePhase.readyToInstall);
      expect(h.installed.single.path, endsWith('Yomi-1.0.2.apk'));
      expect(await h.installed.single.readAsBytes(), apkBytes);
    });

    test('can reopen the installer if the prompt was cancelled', () async {
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();
      await c.check();
      await c.startUpdate();

      await c.startUpdate();

      expect(h.installed, hasLength(2));
      expect(c.phase, UpdatePhase.readyToInstall);
    });

    test('a bad checksum fails and never launches the installer', () async {
      final h = Harness(latest: release('1.0.2'))..checksum = 'b' * 64;
      final c = await h.build();
      await c.check();

      await c.startUpdate();

      expect(c.phase, UpdatePhase.failed);
      expect(c.errorMessage, isNotEmpty);
      expect(h.installed, isEmpty);
    });

    test('a failed update can be retried', () async {
      final h = Harness(latest: release('1.0.2'))..checksum = 'b' * 64;
      final c = await h.build();
      await c.check();
      await c.startUpdate();

      h.checksum = apkHash;
      await c.startUpdate();

      expect(c.phase, UpdatePhase.readyToInstall);
      expect(h.installed, hasLength(1));
    });

    test('reports an installer that could not start', () async {
      final h = Harness(latest: release('1.0.2'))
        ..installError = Exception('no installer');
      final c = await h.build();
      await c.check();

      await c.startUpdate();

      expect(c.phase, UpdatePhase.failed);
    });

    test('retry downloads again if the verified file has gone', () async {
      final h = Harness(latest: release('1.0.2'))
        ..installError = Exception('invalid_path');
      final c = await h.build();
      await c.check();
      await c.startUpdate();
      await File('${h.dir.path}/Yomi-1.0.2.apk').delete();

      h.installError = null;
      await c.startUpdate();

      expect(c.phase, UpdatePhase.readyToInstall);
      expect(await h.installed.single.exists(), isTrue);
    });

    test('a failed update gives way to a newer release', () async {
      final h = Harness(latest: release('1.0.2'))..checksum = 'b' * 64;
      final c = await h.build();
      await c.check();
      await c.startUpdate();
      expect(c.phase, UpdatePhase.failed);

      h.latest = release('1.0.3');
      h.now = h.now.add(const Duration(hours: 7));
      await c.check();

      expect(c.phase, UpdatePhase.available);
      expect(c.release!.version.toString(), '1.0.3');
    });

    test('a failure stays visible when the release has not changed', () async {
      final h = Harness(latest: release('1.0.2'))..checksum = 'b' * 64;
      final c = await h.build();
      await c.check();
      await c.startUpdate();

      h.now = h.now.add(const Duration(hours: 7));
      await c.check();

      expect(c.phase, UpdatePhase.failed);
      expect(c.errorMessage, isNotEmpty);
    });

    test('a check during a download does not disturb it', () async {
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();
      await c.check();

      final update = c.startUpdate();
      expect(c.phase, UpdatePhase.downloading);
      h.now = h.now.add(const Duration(hours: 7));
      await c.check();
      expect(c.phase, isNot(UpdatePhase.available));
      await update;

      expect(c.phase, UpdatePhase.readyToInstall);
    });

    test('removes APKs left by earlier updates', () async {
      final h = Harness(latest: release('1.0.2'));
      final c = await h.build();
      final stale = await File('${h.dir.path}/Yomi-1.0.0.apk').create();
      await c.check();

      await c.startUpdate();

      expect(await stale.exists(), isFalse);
    });
  });

  test('release-page fallback opens the page without installing', () async {
    final h = Harness(
      latest: release('1.0.2'),
      mode: UpdateMode.openReleasePage,
    );
    final c = await h.build();
    await c.check();

    await c.startUpdate();

    expect(h.opened.single.path, '/ginnfx/yomi/releases/tag/v1.0.2');
    expect(h.installed, isEmpty);
    expect(c.phase, UpdatePhase.available);
  });
}
