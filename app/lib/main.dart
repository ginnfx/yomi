import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'core/cover_palette.dart';
import 'core/lyrics.dart';
import 'core/offline/audio_cache.dart';
import 'core/offline/cover_warmer.dart';
import 'core/offline/download_store.dart';
import 'dev_hooks.dart';
import 'state/appearance_controller.dart';
import 'state/connectivity_controller.dart';
import 'state/download_manager.dart';
import 'state/player_controller.dart';
import 'state/profile_controller.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'ui/pages/login_page.dart';
import 'ui/pages/shell_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.yomi.yomi.playback',
    androidNotificationChannelName: 'Yomi playback',
    androidNotificationOngoing: true,
  );

  final settings = await SettingsController.load();
  final appearance = await AppearanceController.load();
  final supportDir = await getApplicationSupportDirectory();
  final profile = await ProfileController.load(
    Directory('${supportDir.path}/profile'),
  );
  final cacheDir = Directory(
    '${(await getApplicationCacheDirectory()).path}/songs',
  );
  await cacheDir.create(recursive: true);
  final downloadsDir = Directory('${supportDir.path}/downloads');
  final store = DownloadStore(downloadsDir);
  await store.load();

  final cache = AudioCache(cacheDir, maxBytes: settings.cacheLimitBytes);
  final connectivity = ConnectivityController();
  final downloads = DownloadManager(
    store: store,
    settings: settings,
    connectivity: connectivity,
    warmCover: warmCovers,
  );
  final session = SessionController(connectivity: connectivity);
  final player = PlayerController(
    AudioPlayer(),
    cache: cache,
    downloads: downloads,
    settings: settings,
    connectivity: connectivity,
  );
  session.addListener(() {
    final client = session.isSignedIn ? session.client : null;
    player.attach(client);
    downloads.attach(client);
  });

  runApp(
    YomiApp(
      session: session,
      player: player,
      downloads: downloads,
      settings: settings,
      connectivity: connectivity,
      cache: cache,
      appearance: appearance,
      profile: profile,
    ),
  );
  await session.restore();
  await runDevHooks(session, player);
  await cache.purgeLegacy();
  await cache.evict();
}

class YomiApp extends StatelessWidget {
  const YomiApp({
    super.key,
    required this.session,
    required this.player,
    required this.downloads,
    required this.settings,
    required this.connectivity,
    required this.cache,
    required this.appearance,
    required this.profile,
  });

  final SessionController session;
  final PlayerController player;
  final DownloadManager downloads;
  final SettingsController settings;
  final ConnectivityController connectivity;
  final AudioCache cache;
  final AppearanceController appearance;
  final ProfileController profile;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(value: session),
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<DownloadManager>.value(value: downloads),
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<ConnectivityController>.value(
          value: connectivity,
        ),
        ChangeNotifierProvider<AppearanceController>.value(value: appearance),
        ChangeNotifierProvider<ProfileController>.value(value: profile),
        Provider<AudioCache>.value(value: cache),
        Provider<CoverPalette>(create: (_) => CoverPalette()),
        Provider<LyricsService>(create: (_) => LyricsService()),
      ],
      child: Consumer<AppearanceController>(
        builder: (context, look, _) => MaterialApp(
          title: 'Yomi',
          debugShowCheckedModeBanner: false,
          theme: buildYomiTheme(look.palette, trueBlack: look.isTrueBlack),
          // Wrapping the Navigator means every page, including pushed ones, reads the live accent.
          builder: (context, child) => YomiTheme(
            palette: look.palette,
            isTrueBlack: look.isTrueBlack,
            child: child!,
          ),
          home: const _Gate(),
        ),
      ),
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    if (session.isRestoring) {
      return AuroraBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.accent,
            ),
          ),
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: session.isSignedIn
          ? const ShellPage(key: ValueKey('shell'))
          : const LoginPage(key: ValueKey('login')),
    );
  }
}
