import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/desktop_installer.dart';

void main() {
  late Directory root;
  late Directory target;
  late Directory work;
  late Directory staged;
  late File helper;

  setUp(() async {
    // Exercise argument handling for spaces, apostrophes and shell metacharacters.
    root = await Directory.systemTemp.createTemp("yomi ' update \$ test ");
    target = await Directory('${root.path}/Yomi').create();
    work = await Directory('${root.path}/staging').create();
    staged = await Directory('${work.path}/Yomi').create();
    await File('${target.path}/version').writeAsString('old');
    await File('${staged.path}/version').writeAsString('new');
    helper = await File('${root.path}/install.sh')
        .writeAsString(desktopInstallScript);
  });

  tearDown(() async => root.delete(recursive: true));

  Future<void> binary(Directory dir, String script) async {
    final file = await File('${dir.path}/yomi')
        .writeAsString('#!/bin/sh\n$script\n');
    await Process.run('chmod', ['+x', file.path]);
  }

  Future<ProcessResult> install() => Process.run('/bin/sh', [
    helper.path,
    '99999999',
    target.path,
    staged.path,
    work.path,
    'linux',
    '${root.path}/install.log',
  ]);

  test('replaces the whole bundle and relaunches from paths containing shell characters', () async {
    await binary(staged, 'sleep 3');
    final result = await install();
    expect(result.exitCode, 0);
    expect(await File('${target.path}/version').readAsString(), 'new');
    expect(await work.exists(), isFalse);
  });

  test(
    'restores the old bundle when the new executable fails to launch',
    () async {
      await binary(staged, 'exit 1');
      await binary(target, 'sleep 3');
      final result = await install();
      expect(result.exitCode, 1);
      expect(await File('${target.path}/version').readAsString(), 'old');
      expect(
        await File('${root.path}/install.log').readAsString(),
        contains('restored'),
      );
    },
  );

  test(
    'restores the old bundle if activating the staged bundle fails',
    () async {
      await staged.delete(recursive: true);
      await binary(target, 'sleep 3');
      final result = await install();
      expect(result.exitCode, 1);
      expect(await File('${target.path}/version').readAsString(), 'old');
    },
  );

  group('AppImage', () {
    late File appImage;
    late File stagedImage;

    Future<File> image(String path, String script) async {
      final file = await File(path).writeAsString('#!/bin/sh\n$script\n');
      await Process.run('chmod', ['+x', file.path]);
      return file;
    }

    Future<ProcessResult> installImage() => Process.run('/bin/sh', [
      helper.path,
      '99999999',
      appImage.path,
      stagedImage.path,
      work.path,
      'appimage',
      '${root.path}/install.log',
    ]);

    setUp(() async {
      appImage = await image('${root.path}/Yomi.AppImage', 'echo old; sleep 3');
    });

    test('swaps in the new AppImage and starts it', () async {
      // Arrange
      stagedImage = await image('${work.path}/Yomi.AppImage', 'sleep 3');

      // Act
      final result = await installImage();

      // Assert
      expect(result.exitCode, 0);
      expect(await appImage.readAsString(), contains('sleep 3'));
      expect(await appImage.readAsString(), isNot(contains('echo old')));
      expect(await work.exists(), isFalse);
    });

    test(
      'puts the old AppImage back when the new one fails to start',
      () async {
        // Arrange
        stagedImage = await image('${work.path}/Yomi.AppImage', 'exit 1');

        // Act
        final result = await installImage();

        // Assert
        expect(result.exitCode, 1);
        expect(await appImage.readAsString(), contains('echo old'));
      },
    );
  });

  test(
    'a Linux AppImage update needs the app to have started from one',
    () async {
      // Arrange
      final installer = DesktopInstaller(appImagePath: '');

      // Act / Assert
      await expectLater(
        installer.installAppImage(File('${root.path}/download')),
        throwsA(isA<Exception>()),
      );
    },
  );
}
