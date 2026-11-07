import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/export/wanted_export.dart';
import 'package:yomi/core/reports/reports_api.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/imports_controller.dart';
import 'package:yomi/state/reports_controller.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/wanted_songs_section.dart';

Map<String, dynamic> _song(String title, int count) => {
  'artist': 'Mira',
  'title': title,
  'count': count,
  'createdMs': 1,
};

ReportsApi _api(
  List<Map<String, dynamic>> songs, {
  List<Uri>? seen,
  int status = 200,
}) => ReportsApi(
  serverUrl: 'http://s',
  auth: SubsonicClient(baseUrl: 'http://s', username: 'u', password: 'p'),
  port: 4534,
  httpClient: MockClient((request) async {
    seen?.add(request.url);
    return http.Response(
      status == 200
          ? jsonEncode({'songs': songs})
          : jsonEncode({'message': 'reports are off'}),
      status,
    );
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

  group('closeWantedFoundIn', () {
    const blueHour = Song(
      id: 's1',
      title: 'Blue Hour',
      artist: 'Mira',
      album: 'A',
      durationSeconds: 200,
    );

    test(
      'drops songs now in the library and closes them on the server',
      () async {
        final sent = <String>[];
        final api = ReportsApi(
          serverUrl: 'http://s',
          auth: SubsonicClient(
            baseUrl: 'http://s',
            username: 'u',
            password: 'p',
          ),
          port: 4534,
          httpClient: MockClient((request) async {
            if (request.method == 'POST') {
              sent.add(request.url.path);
              return http.Response('{}', 200);
            }
            return http.Response(
              jsonEncode({
                'songs': [
                  {'id': 'r1', ..._song('Blue Hour', 2)},
                  {'id': 'r2', ..._song('Green Room', 1)},
                ],
              }),
              200,
            );
          }),
        );
        final controller = await _controller(api);
        await controller.refreshWanted();

        await controller.closeWantedFoundIn([blueHour]);

        expect(controller.wanted.map((s) => s.title), ['Green Room']);
        expect(sent, ['/v1/reports/r1/added']);
      },
    );

    test('keeps the list when nothing matches', () async {
      final controller = await _controller(_api([_song('Green Room', 1)]));
      await controller.refreshWanted();

      await controller.closeWantedFoundIn([blueHour]);

      expect(controller.wanted, hasLength(1));
    });
  });

  group('WantedSongsSection', () {
    Future<void> pumpSection(
      WidgetTester tester,
      ReportsController controller, {
      Future<void> Function(BuildContext, ExportedFile)? shareFile,
      ImportsController? imports,
    }) => tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportsController>.value(value: controller),
          ChangeNotifierProvider<CatalogController>.value(
            value: CatalogController(directory: Directory.systemTemp),
          ),
          ChangeNotifierProvider<ImportsController>.value(
            value:
                imports ??
                ImportsController(
                  file: File('${Directory.systemTemp.path}/none-imports.json'),
                ),
          ),
        ],
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

    testWidgets('says so, with a way to retry, when the list cannot load', (
      tester,
    ) async {
      final controller = await _controller(_api(const [], status: 503));

      await pumpSection(tester, controller);
      await tester.pump();
      await tester.pump();

      expect(find.text('Wanted by everyone'), findsOneWidget);
      expect(find.textContaining("Couldn't load"), findsOneWidget);
      expect(find.textContaining('reports are off'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('says nobody has asked yet instead of vanishing', (
      tester,
    ) async {
      final controller = await _controller(_api(const []));

      await pumpSection(tester, controller);
      await tester.pump();
      await tester.pump();

      expect(find.text('Wanted by everyone'), findsOneWidget);
      expect(find.textContaining('Nobody has asked'), findsOneWidget);
    });

    testWidgets('tells you when this server cannot share the list', (
      tester,
    ) async {
      final controller = await _controller(null);

      await pumpSection(tester, controller);
      await tester.pump();

      expect(find.textContaining("isn't available"), findsOneWidget);
    });

    testWidgets('recovers when the connection is re-attached mid-load', (
      tester,
    ) async {
      final slow = Completer<http.Response>();
      final controller = await _controller(
        ReportsApi(
          serverUrl: 'http://s',
          auth: SubsonicClient(
            baseUrl: 'http://s',
            username: 'u',
            password: 'p',
          ),
          port: 4534,
          httpClient: MockClient((_) => slow.future),
        ),
      );
      await pumpSection(tester, controller);
      await tester.pump();

      // The app swaps the server connection while the first request is still waiting.
      controller.attach(_api([_song('Blue Hour', 2)]));
      await tester.pump();
      await tester.pump();
      slow.complete(http.Response(jsonEncode({'songs': []}), 200));
      await tester.pump();

      expect(find.text('Blue Hour'), findsOneWidget);
      expect(find.text('Loading…'), findsNothing);
    });

    testWidgets('exports everyone\'s wants and my own together', (
      tester,
    ) async {
      final controller = await _controller(_api([_song('Shared One', 2)]));
      // Real file work can't finish inside the test's fake clock.
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('yomi_wanted_mine'),
      ))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final imports = ImportsController(file: File('${dir.path}/i.json'));
      await tester.runAsync(
        () => imports.add('My mix', const [
          ImportEntry(title: 'Only Mine', artist: 'Me'),
        ]),
      );
      ExportedFile? shared;
      await pumpSection(
        tester,
        controller,
        imports: imports,
        shareFile: (_, file) async => shared = file,
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Export list'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text file'));
      await tester.pumpAndSettle();

      expect(shared?.content, 'Mira - Shared One\nMe - Only Mine\n');
    });
  });
}
