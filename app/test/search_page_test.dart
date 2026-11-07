import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/recommendations.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/ai_controller.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/connectivity_controller.dart';
import 'package:yomi/core/taste.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/state/home_controller.dart';
import 'package:yomi/ui/pages/search_page.dart';

import 'support/screen_harness.dart';

class _Home extends ChangeNotifier implements HomeController {
  _Home([this.initialShelves = const []]);
  final List<HomeShelf> initialShelves;
  @override
  List<HomeShelf> get shelves => initialShelves;
  @override
  TasteProfile get taste => TasteProfile.empty;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PagedClient extends SubsonicClient {
  _PagedClient()
    : super(baseUrl: 'http://server', username: 'u', password: 'p');
  final offsets = <int>[];
  @override
  Future<SearchResults> search(
    String query, {
    int count = 40,
    int offset = 0,
  }) async {
    offsets.add(offset);
    return SearchResults(
      songs: [
        for (var i = offset; i < offset + count && i < 80; i++)
          Song(
            id: '$i',
            title: 'Match $i',
            artist: 'X',
            album: 'A',
            durationSeconds: 1,
          ),
      ],
    );
  }
}

class _PagedSession extends FakeSession {
  _PagedSession(this.paged);
  final _PagedClient paged;
  @override
  SubsonicClient get client => paged;
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
          utf8.encode(
            jsonEncode({
              'subsonic-response': {
                'status': 'ok',
                'scanStatus': {'scanning': false, 'lastScan': 'x', 'count': 2},
                'starred2': {},
                'searchResult3': {
                  'song': [
                    {
                      'id': '1',
                      'title': 'Digital Love',
                      'artist': 'Daft Punk',
                      'album': 'Discovery',
                      'albumId': 'd',
                    },
                    {
                      'id': '2',
                      'title': 'Halo',
                      'artist': 'Beyoncé',
                      'album': 'Fierce',
                      'albumId': 'f',
                    },
                  ],
                },
              },
            }),
          ),
          200,
        );
      }),
    );
    await catalog.attach(client, 'account');
    await catalog.sync();
    searchesOnServer = 0;
  });

  tearDown(() => dir.delete(recursive: true));

  Widget page({AiController? ai}) => MultiProvider(
    providers: [
      ChangeNotifierProvider<CatalogController>.value(value: catalog),
      ChangeNotifierProvider<HomeController>.value(value: _Home()),
      if (ai != null)
        ChangeNotifierProvider<AiController>.value(value: ai)
      else
        ChangeNotifierProvider<AiController>(
          create: (_) => AiController(file: File('${dir.path}/labels.json')),
        ),
      ChangeNotifierProvider(
        create: (_) => ConnectivityController(
          changes: const Stream<List<ConnectivityResult>>.empty(),
          check: () async => [ConnectivityResult.wifi],
        ),
      ),
    ],
    child: const Material(child: SearchPage()),
  );

  testWidgets(
    'server paging counts server rows separately from local matches',
    (tester) async {
      final client = _PagedClient();
      final unloaded = CatalogController(
        directory: Directory('${dir.path}/unloaded'),
      );
      const local = Song(
        id: '79',
        title: 'Match 79',
        artist: 'X',
        album: 'A',
        durationSeconds: 1,
      );
      await pumpScreen(
        tester,
        const Material(child: SearchPage()),
        size: const Size(800, 2400),
        extraProviders: [
          ChangeNotifierProvider<SessionController>.value(
            value: _PagedSession(client),
          ),
          ChangeNotifierProvider<CatalogController>.value(value: unloaded),
          ChangeNotifierProvider<HomeController>.value(
            value: _Home([
              const HomeShelf(ShelfKind.jumpBack, 'Local', [local]),
            ]),
          ),
          ChangeNotifierProvider<AiController>.value(
            value: AiController(file: File('${dir.path}/labels.json')),
          ),
        ],
      );
      await tester.enterText(find.byType(TextField).first, 'Match');
      await tester.pump(const Duration(milliseconds: 400));
      await settleScreen(tester);
      final more = find.text('Show more songs');
      await tester.scrollUntilVisible(
        more,
        800,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(more);
      await settleScreen(tester);
      expect(client.offsets, [0, 40]);
      expect(find.text('Match 40'), findsOneWidget);
    },
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

  Future<AiController> labelled(WidgetTester tester) async {
    final ai = AiController(file: File('${dir.path}/labels.json'));
    await tester.runAsync(() async {
      await File('${dir.path}/labels.json').writeAsString(
        jsonEncode({
          'available': true,
          'songs': {
            songTagKey('Daft Punk', 'Digital Love'): {
              'moods': ['happy', 'dreamy'],
              'energy': 'medium',
            },
            songTagKey('Beyoncé', 'Halo'): {
              'moods': ['romantic'],
              'energy': 'medium',
            },
          },
          'artists': {},
        }),
      );
      await ai.load();
    });
    return ai;
  }

  testWidgets('a mood word finds songs with that mood, not that title', (
    tester,
  ) async {
    final ai = await labelled(tester);
    await pumpScreen(tester, page(ai: ai), size: phoneSize);

    await tester.enterText(find.byType(TextField), 'happy');
    await tester.pump();

    expect(find.text('Feels happy'), findsOneWidget);
    expect(find.text('Digital Love'), findsWidgets);
    expect(find.text('Halo'), findsNothing);
    expect(searchesOnServer, 0);
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('recent searches only appear once the search bar is tapped', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      page(),
      size: phoneSize,
      prefs: {
        'recentSearches': ['halo'],
      },
    );
    expect(find.widgetWithText(ActionChip, 'halo'), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(find.widgetWithText(ActionChip, 'halo'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, 'halo'));
    await tester.pump();
    expect(find.text('Halo'), findsWidgets);
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('mood chips appear once the AI is on, and search by mood', (
    tester,
  ) async {
    final ai = await labelled(tester);
    await pumpScreen(tester, page(ai: ai), size: phoneSize);

    expect(find.text('Moods'), findsOneWidget);
    await tester.tap(find.text('Happy'));
    await tester.pump();

    expect(find.text('Feels happy'), findsOneWidget);
    expect(find.text('Digital Love'), findsWidgets);
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
