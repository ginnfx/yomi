import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/quick_song_actions.dart';

import 'support/screen_harness.dart';

class _Session extends FakeSession {
  _Session(this._client);
  final SubsonicClient _client;
  @override
  SubsonicClient get client => _client;
}

Song _song({bool isStarred = false}) => Song(
  id: 's1',
  title: 'T',
  artist: 'A',
  album: 'B',
  durationSeconds: 1,
  isStarred: isStarred,
);

void main() {
  late List<String> calls;

  Future<void> pumpButton(WidgetTester tester, Song song, {int status = 200}) {
    calls = [];
    final client = SubsonicClient(
      baseUrl: 'http://s',
      username: 'u',
      password: 'p',
      httpClient: MockClient((request) async {
        calls.add(request.url.pathSegments.last);
        return http.Response(
          status == 200
              ? '{"subsonic-response":{"status":"ok"}}'
              : '{"subsonic-response":{"status":"failed"}}',
          status,
        );
      }),
    );
    return tester.pumpWidget(
      ChangeNotifierProvider<SessionController>.value(
        value: _Session(client),
        child: MaterialApp(
          theme: buildYomiTheme(accentPalettes.first),
          home: YomiTheme(
            palette: accentPalettes.first,
            isTrueBlack: false,
            child: Scaffold(
              body: Center(child: LikeButton(song: song)),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tapping an unliked song likes it at once', (tester) async {
    await pumpButton(tester, _song());

    await tester.tap(find.byTooltip('Like'));
    await tester.pump();

    expect(find.byTooltip('Unlike'), findsOneWidget);
    expect(calls, ['star']);
  });

  testWidgets('tapping a liked song unlikes it', (tester) async {
    await pumpButton(tester, _song(isStarred: true));

    await tester.tap(find.byTooltip('Unlike'));
    await tester.pump();

    expect(find.byTooltip('Like'), findsOneWidget);
    expect(calls, ['unstar']);
  });

  testWidgets('shows the new song when the player moves on', (tester) async {
    await pumpButton(tester, _song(isStarred: true));
    expect(find.byTooltip('Unlike'), findsOneWidget);

    await pumpButton(tester, _song());

    expect(find.byTooltip('Like'), findsOneWidget);
  });
}
