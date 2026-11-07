import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/recommendations.dart';
import 'package:yomi/core/taste.dart';
import 'package:yomi/state/ai_controller.dart';
import 'package:yomi/state/catalog_controller.dart';
import 'package:yomi/state/home_controller.dart';
import 'package:yomi/state/messages_controller.dart';
import 'package:yomi/state/playback_sync_controller.dart';
import 'package:yomi/ui/pages/home_page.dart';
import 'package:yomi/ui/settings/profile_section.dart';

import 'package:yomi/ui/widgets/shimmer.dart';

import 'support/screen_harness.dart';

class _FakeHome extends ChangeNotifier implements HomeController {
  _FakeHome(this.shelves);

  @override
  final List<HomeShelf> shelves;
  @override
  bool get isLoading => false;
  @override
  Object? get error => null;
  @override
  List<Playlist> get quickPlaylists => const [];
  @override
  List<Song> get quickSongs => _songs('Quick');

  @override
  TasteProfile get taste => TasteProfile.empty;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An empty library, so Made for you has no mixes to show.
class _FakeCatalog extends ChangeNotifier implements CatalogController {
  @override
  List<Song> get songs => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAi extends ChangeNotifier implements AiController {
  @override
  int get labelledCount => 0;
  @override
  bool get isAvailable => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSync extends ChangeNotifier implements PlaybackSyncController {
  @override
  bool get enabled => false;
  @override
  Null get remote => null;
  @override
  Null get offer => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Song> _songs(String prefix) => [
  for (var i = 0; i < 6; i++)
    Song(
      id: '$prefix$i',
      title: '$prefix song $i',
      artist: 'The Examples',
      album: 'Long Roads',
      durationSeconds: 200,
    ),
];

void main() {
  setUpAll(loadAppFonts);

  Widget home() => MultiProvider(
    providers: [
      ChangeNotifierProvider<HomeController>.value(
        value: _FakeHome([
          HomeShelf(ShelfKind.jumpBack, 'Jump back in', _songs('Back')),
          HomeShelf(
            ShelfKind.becauseYouPlayed,
            'Because you played The Examples',
            _songs('Like'),
          ),
          HomeShelf(ShelfKind.timeOfDay, 'Evening mix', _songs('Mix')),
        ]),
      ),
      ChangeNotifierProvider<PlaybackSyncController>.value(value: _FakeSync()),
      ChangeNotifierProvider<CatalogController>.value(value: _FakeCatalog()),
      ChangeNotifierProvider<AiController>.value(value: _FakeAi()),
      ChangeNotifierProvider<MessagesController>(
        create: (_) => MessagesController(),
      ),
    ],
    child: Material(child: HomePage(greetingTime: DateTime(2026, 1, 1, 15))),
  );

  testWidgets('real content on the first frame, with no skeleton', (
    tester,
  ) async {
    await pumpScreen(tester, home(), size: phoneSize);

    expect(find.text('Quick song 0'), findsOneWidget);
    expect(find.text('Jump back in'), findsOneWidget);
    expect(find.byType(Shimmer), findsNothing);
  });

  final hideQuick = <String, Object>{
    'homeHidden': <String>['quick'],
  };

  testWidgets('shows each shelf with its title and the avatar on the left', (
    tester,
  ) async {
    await pumpScreen(tester, home(), size: phoneSize, prefs: hideQuick);
    expect(find.text('Jump back in'), findsOneWidget);
    expect(find.text('Because you played The Examples'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(ProfileAvatar)).dx,
      lessThan(phoneSize.width / 2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('screenshot', (tester) async {
    await pumpScreen(tester, home(), size: phoneSize, prefs: hideQuick);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_phone.png'),
    );
  }, skip: !Platform.isMacOS);

  testWidgets('screenshot in the light theme', (tester) async {
    await pumpScreen(
      tester,
      home(),
      size: phoneSize,
      prefs: hideQuick,
      brightness: Brightness.light,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_phone_light.png'),
    );
  }, skip: !Platform.isMacOS);
}
