import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/app_update.dart';
import 'package:yomi/state/update_controller.dart';
import 'package:yomi/ui/widgets/update_banner.dart';

final _apk = utf8.encode('apk');

Future<(UpdateController, List<Uri>)> _controller(
  WidgetTester tester, {
  UpdateMode mode = UpdateMode.androidInstall,
  bool isChecksumBad = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final opened = <Uri>[];
  final base = 'https://github.com/ginnfx/yomi/releases/download/v1.0.2';
  final json = {
    'tag_name': 'v1.0.2',
    'body': 'Lyrics are now always visible',
    'html_url': 'https://github.com/ginnfx/yomi/releases/tag/v1.0.2',
    'assets': [
      {'name': 'Yomi-android.apk', 'browser_download_url': '$base/Yomi-android.apk'},
      {
        'name': 'Yomi-android.apk.sha256',
        'browser_download_url': '$base/Yomi-android.apk.sha256',
      },
    ],
  };
  final dir = await tester.runAsync(
    () => Directory.systemTemp.createTemp('yomi_banner'),
  );
  addTearDown(() => dir!.delete(recursive: true));
  final controller = UpdateController(
    currentVersion: AppVersion.tryParse('1.0.1')!,
    mode: mode,
    client: UpdateClient(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/latest')) {
          return http.Response(jsonEncode(json), 200);
        }
        if (path.endsWith('.sha256')) {
          return http.Response(
            isChecksumBad ? 'b' * 64 : sha256.convert(_apk).toString(),
            200,
          );
        }
        return http.Response.bytes(_apk, 200);
      }),
    ),
    prefs: await SharedPreferences.getInstance(),
    downloadDir: dir!,
    install: (_) async {},
    openPage: (uri) async => opened.add(uri),
    now: () => DateTime(2026, 11, 4),
  );
  return (controller, opened);
}

Future<void> _pump(WidgetTester tester, UpdateController controller) async {
  await tester.runAsync(controller.check);
  await tester.pumpWidget(
    ChangeNotifierProvider<UpdateController>.value(
      value: controller,
      child: const MaterialApp(home: Scaffold(body: UpdateBanner())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows nothing when there is no update', (tester) async {
    final (controller, _) = await _controller(tester);

    await tester.pumpWidget(
      ChangeNotifierProvider<UpdateController>.value(
        value: controller,
        child: const MaterialApp(home: Scaffold(body: UpdateBanner())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Yomi'), findsNothing);
  });

  testWidgets('announces the new version with an Update action', (tester) async {
    final (controller, _) = await _controller(tester);

    await _pump(tester, controller);

    expect(find.text('Yomi 1.0.2 is available'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
  });

  testWidgets('tapping the banner shows what changed', (tester) async {
    final (controller, _) = await _controller(tester);
    await _pump(tester, controller);

    await tester.tap(find.text('Yomi 1.0.2 is available'));
    await tester.pumpAndSettle();

    expect(find.text('Lyrics are now always visible'), findsOneWidget);
  });

  testWidgets('dismiss hides the banner', (tester) async {
    final (controller, _) = await _controller(tester);
    await _pump(tester, controller);

    await tester.tap(find.byTooltip('Not now'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.text('Yomi 1.0.2 is available'), findsNothing);
  });

  testWidgets('Update downloads and leaves an Install action', (tester) async {
    final (controller, _) = await _controller(tester);
    await _pump(tester, controller);

    await tester.runAsync(controller.startUpdate);
    await tester.pumpAndSettle();

    expect(find.text('Update ready to install'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('a failure explains itself and offers Retry', (tester) async {
    final (controller, _) = await _controller(tester, isChecksumBad: true);
    await _pump(tester, controller);

    await tester.runAsync(controller.startUpdate);
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining("couldn't"), findsOneWidget);
  });

  testWidgets('macOS offers a Download link to the release page', (tester) async {
    final (controller, opened) = await _controller(
      tester,
      mode: UpdateMode.openReleasePage,
    );
    await _pump(tester, controller);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(opened.single.path, '/ginnfx/yomi/releases/tag/v1.0.2');
  });
}
