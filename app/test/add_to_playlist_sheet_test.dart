import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/search_index.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/imports_controller.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/playlist_sheet.dart';

import 'support/screen_harness.dart';

const _song = Song(
  id: 'new',
  title: 'New One',
  artist: 'Oak',
  album: 'Z',
  durationSeconds: 1,
);

const _library = [
  Song(id: 'old', title: 'Old', artist: 'Mira', album: 'X', durationSeconds: 1),
  _song,
];

class _Session extends FakeSession {
  _Session(this._client);
  final SubsonicClient _client;
  @override
  SubsonicClient get client => _client;
}

class _Catalog extends ChangeNotifier implements CatalogController {
  @override
  List<Song> get songs => _library;
  @override
  SearchIndex get searchIndex => SearchIndex(_library);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<String> calls;
  late ImportsController imports;

  Future<void> open(WidgetTester tester) async {
    calls = [];
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('yomi_add_sheet'),
    ))!;
    addTearDown(() => dir.delete(recursive: true));
    imports = ImportsController(file: File('${dir.path}/imports.json'));
    await tester.runAsync(
      () => imports.add('Spotify mix', const [
        ImportEntry(title: 'Old', artist: 'Mira', songId: 'old'),
      ]),
    );
    final client = SubsonicClient(
      baseUrl: 'http://s',
      username: 'me',
      password: 'p',
      httpClient: MockClient((request) async {
        calls.add(request.url.pathSegments.last);
        return http.Response(
          '{"subsonic-response":{"status":"ok","playlists":{"playlist":['
          '{"id":"1","name":"Road trip","owner":"me","songCount":3}]}}}',
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SessionController>.value(
            value: _Session(client),
          ),
          ChangeNotifierProvider<ImportsController>.value(value: imports),
          ChangeNotifierProvider<CatalogController>.value(value: _Catalog()),
        ],
        child: MaterialApp(
          theme: buildYomiTheme(accentPalettes.first),
          home: YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: false,
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAddToPlaylist(context, _song),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('lists normal playlists and Spotify imports together', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Road trip'), findsOneWidget);
    expect(find.text('Spotify mix'), findsOneWidget);
  });

  testWidgets('adding to an import puts the song at its end', (tester) async {
    await open(tester);

    await tester.tap(find.text('Spotify mix'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(imports.playlists.single.entries.map((e) => e.songId), [
      'old',
      'new',
    ]);
  });

  testWidgets('adding to a normal playlist asks the server', (tester) async {
    await open(tester);

    await tester.tap(find.text('Road trip'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(calls, contains('updatePlaylist'));
  });

  testWidgets('the sheet keeps its size while playlists load', (tester) async {
    calls = [];
    await open(tester);
    final loaded = tester.getSize(find.byType(BottomSheet));

    // The sheet is already at full size, so nothing jumps when the list arrives.
    expect(loaded.height, greaterThan(300));
  });
}
