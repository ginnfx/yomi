import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/export/wanted_export.dart';
import 'package:yomi/core/reports/reports_api.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/reports_controller.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/wanted_songs_section.dart';

import 'support/screen_harness.dart';

Map<String, dynamic> _song(String title, int count) => {
  'artist': 'Mira',
  'title': title,
  'count': count,
  'createdMs': 1,
};

ReportsApi _api(List<Map<String, dynamic>> songs, {List<Uri>? seen}) =>
    ReportsApi(
      serverUrl: 'http://s',
      auth: SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'p'),
      port: 4534,
      httpClient: MockClient((request) async {
        seen?.add(request.url);
        return http.Response(jsonEncode({'songs': songs}), 200);
      }),
    );

Future<ReportsController> _controller(ReportsApi? api) async {
  SharedPreferences.setMockInitialValues({});
  final controller = ReportsController(await SharedPreferences.getInstance());
  controller.attach(api);
  return controller;
}

void main() {
  group('ReportsApi.wanted', () {
    test('reads the shared list from the server', () async {
      final seen = <Uri>[];
      final api = _api([_song('Blue Hour', 3)], seen: seen);

      final songs = await api.wanted();

      expect(songs.single.title, 'Blue Hour');
      expect(songs.single.count, 3);
      expect(seen.single.path, '/v1/reports/wanted');
    });

    test('skips entries that are not songs', () async {
      final api = _api([
        _song('Fine', 1),
        {'artist': 1},
      ]);

      expect((await api.wanted()).map((s) => s.title), ['Fine']);
    });
  });

  group('ReportsController.refreshWanted', () {
    test('keeps the list for screens to show', () async {
      final controller = await _controller(
        _api([_song('A', 1), _song('B', 2)]),
      );

      await controller.refreshWanted();

      expect(controller.wanted.map((s) => s.title), ['A', 'B']);
      expect(controller.isWantedLoaded, isTrue);
    });

    test('says nothing was loaded when the server cannot be asked', () async {
      final controller = await _controller(null);

      await controller.refreshWanted();

      expect(controller.wanted, isEmpty);
      expect(controller.isWantedLoaded, isFalse);
    });

    test('forgets the list when the server changes', () async {
      final controller = await _controller(_api([_song('A', 1)]));
      await controller.refreshWanted();

      controller.attach(null);

      expect(controller.wanted, isEmpty);
    });
  });

  group('WantedSongsSection', () {
    Future<void> pumpSection(
      WidgetTester tester,
      ReportsController controller, {
      Future<void> Function(BuildContext, ExportedFile)? shareFile,
    }) => tester.pumpWidget(
      ChangeNotifierProvider<ReportsController>.value(
        value: controller,
        child: MaterialApp(
          theme: buildYomiTheme(accentPalettes.first),
          home: YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: false,
            child: Scaffold(
              body: SingleChildScrollView(
                child: WantedSongsSection(shareFile: shareFile),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('shows what everyone wants, with how many want it', (
      tester,
    ) async {
      final controller = await _controller(_api([_song('Blue Hour', 3)]));

      await pumpSection(tester, controller);
      await tester.pump();
      await tester.pump();

      expect(find.text('Wanted by everyone'), findsOneWidget);
      expect(find.text('Blue Hour'), findsOneWidget);
      expect(find.textContaining('3 people'), findsOneWidget);
    });

    testWidgets('shows five at first and all of them on request', (
      tester,
    ) async {
      final controller = await _controller(
        _api([for (var i = 0; i < 8; i++) _song('Song $i', 1)]),
      );
      await pumpSection(tester, controller);
      await tester.pump();
      await tester.pump();
      expect(find.text('Song 4'), findsOneWidget);
      expect(find.text('Song 5'), findsNothing);

      await tester.tap(find.text('Show all 8'));
      await tester.pump();

      expect(find.text('Song 7'), findsOneWidget);
    });

    testWidgets('stays out of the way when nobody wants anything', (
      tester,
    ) async {
      final controller = await _controller(_api(const []));

      await pumpSection(tester, controller);
      await tester.pump();
      await tester.pump();

      expect(find.text('Wanted by everyone'), findsNothing);
    });

    testWidgets('exports the list in the format picked', (tester) async {
      final controller = await _controller(_api([_song('Blue Hour', 3)]));
      ExportedFile? shared;
      await pumpSection(
        tester,
        controller,
        shareFile: (_, file) async => shared = file,
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Export list'));
      await tester.pumpAndSettle();
      expect(find.text('Text file'), findsOneWidget);
      expect(find.text('Spreadsheet'), findsOneWidget);
      expect(find.text('JSON'), findsOneWidget);
      await tester.tap(find.text('Spreadsheet'));
      await tester.pumpAndSettle();

      expect(shared?.name, 'yomi-wanted-songs.csv');
      expect(shared?.content, contains('Mira,Blue Hour,3'));
    });

    testWidgets('copies the list as text', (tester) async {
      final controller = await _controller(_api([_song('Blue Hour', 3)]));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpSection(tester, controller);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Export list'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy as text'));
      await tester.pumpAndSettle();

      expect(copied, 'Mira - Blue Hour\n');
    });
  });
}
