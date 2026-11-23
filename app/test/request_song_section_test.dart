import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/reports/reports_api.dart';
import 'package:yomi/core/song_database.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/reports_controller.dart';
import 'package:yomi/ui/widgets/request_song_section.dart';

void main() {
  testWidgets('a database selection becomes one shared song request', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final reports = ReportsController(await SharedPreferences.getInstance());
    final posted = <Map<String, dynamic>>[];
    reports.attach(
      ReportsApi(
        serverUrl: 'http://server',
        port: 4534,
        auth: SubsonicClient(
          baseUrl: 'http://server',
          username: 'u',
          password: 'p',
        ),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            posted.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('{}', 201);
          }
          return http.Response('{"songs":[]}', 200);
        }),
      ),
    );
    final database = SongDatabase(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'results': [
              {
                'artistName': 'Nova',
                'trackName': 'Missing Recording',
                'collectionName': 'Album',
              },
            ],
          }),
          200,
        ),
      ),
    );
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('request-section'),
    ))!;
    final catalog = CatalogController(directory: directory);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportsController>.value(value: reports),
          ChangeNotifierProvider<CatalogController>.value(value: catalog),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RequestSongSection(database: database),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pumpAndSettle();
    expect(find.text('Missing Recording'), findsOneWidget);
    await tester.tap(find.text('Request'));
    await tester.pumpAndSettle();
    expect(posted, hasLength(1));
    expect(posted.single['kind'], 'missing_song');
    expect(posted.single['artist'], 'Nova');
    expect(posted.single['title'], 'Missing Recording');
    expect(find.text('Requested'), findsOneWidget);
    await tester.tap(find.text('Requested'));
    expect(posted, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    database.close();
    reports.dispose();
    catalog.dispose();
    await tester.runAsync(() => directory.delete(recursive: true));
  });
}
