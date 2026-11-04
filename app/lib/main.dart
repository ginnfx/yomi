import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/apk_installer.dart';
import 'core/app_update.dart';
import 'core/cover_palette.dart';
import 'core/listening/auto_download_ledger.dart';
import 'core/listening/play_history.dart';
import 'core/listening/scrobble_queue.dart';
import 'core/lyrics.dart';
import 'core/offline/audio_cache.dart';
import 'core/offline/cover_warmer.dart';
import 'core/offline/download_store.dart';
import 'dev_hooks.dart';
import 'state/appearance_controller.dart';
import 'state/connectivity_controller.dart';
import 'state/download_manager.dart';
import 'state/listening_controller.dart';
import 'state/player_controller.dart';
import 'state/playback_sync_controller.dart';
import 'state/profile_controller.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/update_controller.dart';
import 'state/upload_queue.dart';
import 'ui/pages/login_page.dart';
import 'ui/pages/shell_page.dart';
import 'ui/theme.dart';
import 'ui/widgets/desktop_controls.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

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
  final legacyCacheDir = Directory(
    '${(await getApplicationCacheDirectory()).path}/songs',
  );
  var cacheDir = Platform.isMacOS
      ? Directory('${supportDir.path}/song-cache')
      : legacyCacheDir;
  if (Platform.isMacOS &&
      !await cacheDir.exists() &&
      await legacyCacheDir.exists()) {
    try {
      await legacyCacheDir.rename(cacheDir.path);
    } on FileSystemException {
      cacheDir = legacyCacheDir;
    }
  }
  await cacheDir.create(recursive: true);
  final downloadsDir = Directory('${supportDir.path}/downloads');
  final store = DownloadStore(downloadsDir);
  await store.load();

  final cache = AudioCache(cacheDir, maxBytes: settings.cacheLimitBytes);
  await cache.purgeLegacy();
  await cache.evict();
  final connectivity = ConnectivityController();
  final prefs = await SharedPreferences.getInstance();
  final ledger = AutoDownloadLedger(prefs);
  final downloads = DownloadManager(
    store: store,
    settings: settings,
    connectivity: connectivity,
    warmCover: warmCovers,
    ledger: ledger,
  );
  final session = SessionController(connectivity: connectivity);
  final player = PlayerController(
    AudioPlayer(),
    cache: cache,
    downloads: downloads,
    settings: settings,
    connectivity: connectivity,
  );
  final listeningDir = '${supportDir.path}/listening';
  final history = PlayHistory(File('$listeningDir/history.json'));
  final scrobbles = ScrobbleQueue(File('$listeningDir/scrobbles.json'));
  await history.load();
  await scrobbles.load();
  final listening = ListeningController(
    history: history,
    scrobbles: scrobbles,
    ledger: ledger,
    downloads: downloads,
    settings: settings,
    connectivity: connectivity,
    trackChanges: player,
    currentSong: () => player.current,
    isPlaying: () => player.isPlaying,
    positions: player.positionStream,
  );
  final lyrics = LyricsService(
    store: LyricsStore(Directory('${supportDir.path}/lyrics')),
  );
  player.onUpcomingSong = (client, song) {
    unawaited(lyrics.forSong(client, song));
  };
  final uploadsDir = '${supportDir.path}/uploads';
  final uploads = UploadQueue(
    queueFile: File('$uploadsDir/queue.json'),
    hashCacheFile: File('$uploadsDir/hashes.json'),
  );
  await uploads.load();
  var deviceId = prefs.getString('playbackDeviceId');
  if (deviceId == null) {
    deviceId =
        'Yomi/${Platform.operatingSystem}/${List.generate(12, (_) => Random.secure().nextInt(16).toRadixString(16)).join()}';
    await prefs.setString('playbackDeviceId', deviceId);
  }
  final sync = PlaybackSyncController(
    player: player,
    settings: settings,
    deviceId: deviceId,
    pollInterval: Duration(seconds: Platform.isMacOS ? 2 : 5),
  );
  session.addListener(() {
    final client = session.isSignedIn ? session.client : null;
    player.attach(client);
    downloads.attach(client);
    listening.attach(client);
    uploads.attach(
      client == null ? null : session.uploader,
      loadSnapshot: client == null ? null : snapshotLoaderFor(client),
    );
    sync.attach(client);
  });

  final updates = await _buildUpdateController(prefs);
  AppLifecycleListener(onResume: () => unawaited(updates.check()));

  runApp(
    YomiApp(
      updates: updates,
      sync: sync,
      session: session,
      player: player,
      downloads: downloads,
      settings: settings,
      connectivity: connectivity,
      cache: cache,
      appearance: appearance,
      profile: profile,
      lyrics: lyrics,
      history: history,
      uploads: uploads,
    ),
  );
  unawaited(updates.check());
  await session.restore();
  await runDevHooks(session, player);
}

Future<UpdateController> _buildUpdateController(SharedPreferences prefs) async {
  final info = await PackageInfo.fromPlatform();
  final version = AppVersion.tryParse(info.version);
  // Must stay in step with res/xml/update_paths.xml on Android.
  final cacheDir = await getApplicationCacheDirectory();
  return UpdateController(
    currentVersion: version ?? const AppVersion(0, 0, 0),
    mode: _updateMode(hasValidVersion: version != null),
    client: UpdateClient(),
    prefs: prefs,
    downloadDir: Directory('${cacheDir.path}/updates'),
    install: launchApkInstaller,
    openPage: openReleasePage,
  );
}

UpdateMode _updateMode({required bool hasValidVersion}) {
  if (!hasValidVersion) return UpdateMode.disabled;
  if (Platform.isAndroid) return UpdateMode.androidInstall;
  if (Platform.isMacOS) return UpdateMode.openReleasePage;
  return UpdateMode.disabled;
}

class YomiApp extends StatelessWidget {
  const YomiApp({
    super.key,
    required this.updates,
    required this.sync,
    required this.session,
    required this.player,
    required this.downloads,
    required this.settings,
    required this.connectivity,
    required this.cache,
    required this.appearance,
    required this.profile,
    required this.lyrics,
    required this.history,
    required this.uploads,
  });

  final UpdateController updates;
  final PlaybackSyncController sync;
  final SessionController session;
  final PlayerController player;
  final DownloadManager downloads;
  final SettingsController settings;
  final ConnectivityController connectivity;
  final AudioCache cache;
  final AppearanceController appearance;
  final ProfileController profile;
  final LyricsService lyrics;
  final PlayHistory history;
  final UploadQueue uploads;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<UpdateController>.value(value: updates),
        ChangeNotifierProvider<UploadQueue>.value(value: uploads),
        ChangeNotifierProvider<PlaybackSyncController>.value(value: sync),
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
        Provider<LyricsService>.value(value: lyrics),
        Provider<PlayHistory>.value(value: history),
      ],
      child: Consumer<AppearanceController>(
        builder: (context, look, _) => MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'Yomi',
          debugShowCheckedModeBanner: false,
          theme: buildYomiTheme(look.palette, trueBlack: look.isTrueBlack),
          // Wrapping the Navigator means every page, including pushed ones, reads the live accent.
          builder: (context, child) => YomiTheme(
            palette: look.palette,
            isTrueBlack: look.isTrueBlack,
            child: Platform.isMacOS
                ? DesktopControls(navigatorKey: _navigatorKey, child: child!)
                : child!,
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
      return PageBackground(
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
