import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/recommendations.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/state/home_controller.dart';
import 'package:yomi/ui/pages/search_page.dart';

import 'support/screen_harness.dart';

class _Home extends ChangeNotifier implements HomeController {
  @override
  List<HomeShelf> get shelves => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late CatalogController catalog;
  var searchesOnServer = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('search_page');
    searchesOnServer = 0;
    catalog = CatalogController(directory: dir);
    final client = SubsonicClient(
      baseUrl: 'http://s',
      username: 'u',
      password: 'p',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('search3')) searchesOnServer++;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'scanStatus': {'scanning': false, 'lastScan': 'x', 'count': 2},
              'starred2': {},
              'searchResult3': {
                'song': [
                  {'id': '1', 'title': 'Digital Love', 'artist': 'Daft Punk', 'album': 'Discovery', 'albumId': 'd'},
                  {'id': '2', 'title': 'Halo', 'artist': 'Beyoncé', 'album': 'Fierce', 'albumId': 'f'},
                ],
              },
            },
          })),
          200,
        );
      }),
    );
    await catalog.attach(client, 'account');
    await catalog.sync();
    searchesOnServer = 0;
  });

  tearDown(() => dir.delete(recursive: true));

  Widget page() => MultiProvider(
    providers: [
      ChangeNotifierProvider<CatalogController>.value(value: catalog),
      ChangeNotifierProvider<HomeController>.value(value: _Home()),
      ChangeNotifierProvider(
        create: (_) => ConnectivityController(
          changes: const Stream<List<ConnectivityResult>>.empty(),
          check: () async => [ConnectivityResult.wifi],
        ),
      ),
    ],
    child: const Material(child: SearchPage()),
  );

  testWidgets('a typo finds the song straight away, with no server search', (
    tester,
  ) async {
    await pumpScreen(tester, page(), size: phoneSize);

    await tester.enterText(find.byType(TextField), 'digitl');
    await tester.pump();

    expect(find.textContaining('Top result'), findsOneWidget);
    expect(find.text('Digital Love'), findsWidgets);
    expect(find.text('Halo'), findsNothing);
    expect(searchesOnServer, 0);
    // Lets the top result's artwork lookup finish in test time.
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('finds artists and albums too', (tester) async {
    await pumpScreen(tester, page(), size: phoneSize);

    await tester.enterText(find.byType(TextField), 'beyonce');
    await tester.pump();
    expect(find.textContaining('Artist · 1 songs'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'discovery');
    await tester.pump();
    expect(find.textContaining('Album · Daft Punk'), findsOneWidget);
  });

  testWidgets('says so when nothing matches', (tester) async {
    await pumpScreen(tester, page(), size: phoneSize);

    await tester.enterText(find.byType(TextField), 'zzzzzz');
    await tester.pump();

    expect(find.text('Nothing for "zzzzzz"'), findsOneWidget);
  });
}
