import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/cover_palette.dart';
import 'package:yomi/core/lyrics.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/download_manager.dart';
import 'package:yomi/state/player_controller.dart';
import 'package:yomi/state/profile_controller.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/state/settings.dart';
import 'package:yomi/ui/theme.dart';

const Size phoneSize = Size(390, 844);
const Size wideSize = Size(1280, 800);

const Song demoSong = Song(
  id: 'demo',
  title: 'Night Drive',
  artist: 'The Examples',
  album: 'Long Roads',
  durationSeconds: 214,
);

final Lyrics demoLyrics = Lyrics.parseLrc('''
[00:01.00]Headlights on the empty road
[00:05.00]This one line runs on and on until it has to wrap around the screen
[00:10.00]Nothing left to say tonight
[00:15.00]Radio low
[00:20.00]We keep driving
[00:25.00]Into the morning light
[00:30.00]Headlights on the empty road
[00:35.00]Nothing left to say tonight
''');

/// Loads the real app font and icons so screenshots look like the app.
Future<void> loadAppFonts() async {
  final jakarta = FontLoader(kFontFamily);
  for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
    jakarta.addFont(
      File('assets/fonts/PlusJakartaSans-$weight.ttf')
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)),
    );
  }
  await jakarta.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!icons.existsSync()) return;
  final loader = FontLoader('MaterialIcons')
    ..addFont(icons.readAsBytes().then((b) => ByteData.sublistView(b)));
  await loader.load();
}

class FakeLyricsService implements LyricsService {
  FakeLyricsService(this.lyrics);

  final Lyrics? lyrics;

  @override
  Future<Lyrics?> forSong(SubsonicClient client, Song song) async => lyrics;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakePlayer extends ChangeNotifier implements PlayerController {
  FakePlayer(this._song, {this.fakePosition = const Duration(seconds: 12)});

  final Song? _song;
  final Duration fakePosition;

  @override
  Song? get current => _song;
  @override
  bool get isPlaying => true;
  @override
  bool get isBuffering => false;
  @override
  bool isAvailableNow(Song song) => true;
  @override
  bool get canSkipNext => true;
  @override
  int get userSkips => 0;
  @override
  bool get isShuffled => false;
  @override
  LoopMode get loopMode => LoopMode.off;
  @override
  String? get error => null;
  @override
  List<Song> get queue => [if (_song != null) _song];
  @override
  int? get index => 0;
  @override
  Stream<Duration> get positionStream => Stream.value(fakePosition);
  @override
  Stream<Duration?> get durationStream => Stream.value(_song?.duration);
  @override
  Future<void> togglePlay() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSession extends ChangeNotifier implements SessionController {
  @override
  String get username => 'demo';
  @override
  String get serverUrl => 'http://server';
  @override
  ActiveRoute get route => ActiveRoute.home;
  @override
  bool get hasHomeAddress => true;
  @override
  SubsonicClient get client =>
      SubsonicClient(baseUrl: 'http://server', username: 'u', password: 'p');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDownloads extends ChangeNotifier implements DownloadManager {
  @override
  DownloadStatus statusOf(String songId) => DownloadStatus.none;
  @override
  double progressOf(String songId) => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Wraps [child] in the providers and theme a page expects, at [size].
Future<void> pumpScreen(
  WidgetTester tester,
  Widget child, {
  required Size size,
  Song? song = demoSong,
  Lyrics? lyrics,
  Map<String, Object> prefs = const {},
  Directory? profileDir,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sharedPrefs = await SharedPreferences.getInstance();
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerController>.value(value: FakePlayer(song)),
        ChangeNotifierProvider<SessionController>.value(value: FakeSession()),
        ChangeNotifierProvider<DownloadManager>.value(value: FakeDownloads()),
        ChangeNotifierProvider<SettingsController>.value(
          value: SettingsController(sharedPrefs),
        ),
        ChangeNotifierProvider<ProfileController>.value(
          value: ProfileController(
            sharedPrefs,
            profileDir ?? Directory.systemTemp,
          ),
        ),
        Provider<LyricsService>.value(value: FakeLyricsService(lyrics)),
        Provider<CoverPalette>.value(value: CoverPalette()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildYomiTheme(accentPalettes.first),
        builder: (context, inner) => YomiTheme(
          palette: accentPalettes.first,
          isTrueBlack: false,
          child: inner!,
        ),
        home: child,
      ),
    ),
  );
  await settleScreen(tester);
}

/// Lets streams deliver and animations finish; pumpAndSettle would never return
/// because of the player's indeterminate widgets.
Future<void> settleScreen(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}
