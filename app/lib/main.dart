import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/ai/ai_api.dart';
import 'core/apk_installer.dart';
import 'core/app_update.dart';
import 'core/audio/yomi_audio_handler.dart';
import 'core/catalog_cache.dart';
import 'core/cover_palette.dart';
import 'core/listening/auto_download_ledger.dart';
import 'core/listening/history_api.dart';
import 'core/listening/past_favourites.dart';
import 'core/listening/play_history.dart';
import 'core/listening/scrobble_queue.dart';
import 'core/lyrics.dart';
import 'core/offline/audio_cache.dart';
import 'core/offline/cover_warmer.dart';
import 'core/offline/download_store.dart';
import 'core/offline/outbox.dart';
import 'core/tunnel/tunnel_bridge.dart';
import 'core/spotify/imported_playlist.dart';
import 'core/subsonic_client.dart';
import 'dev_hooks.dart';
import 'state/appearance_controller.dart';
import 'state/connectivity_controller.dart';
import 'state/download_manager.dart';
import 'state/ai_controller.dart';
import 'state/catalog_controller.dart';
import 'state/home_controller.dart';
import 'state/imports_controller.dart';
import 'state/offline_keeper.dart';
import 'state/listening_controller.dart';
import 'state/listening_log.dart';
import 'state/messages_controller.dart';
import 'state/player_controller.dart';
import 'state/playback_sync_controller.dart';
import 'state/profile_controller.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/tunnel_controller.dart';
import 'state/update_controller.dart';
import 'state/upload_queue.dart';
import 'ui/pages/login_page.dart';
import 'ui/pages/shell_page.dart';
import 'ui/theme.dart';
import 'ui/widgets/desktop_controls.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  final cache = AudioCache(cacheDir, maxBytes: settings.storageLimitBytes);
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
    queueFile: File('${downloadsDir.path}/queue.json'),
    onSaved: cache.remove,
  );
  await downloads.loadQueue();
  final tunnel = TunnelController(
    bridge: const MethodChannelTunnelBridge(),
    prefs: prefs,
    stateDir: Directory('${supportDir.path}/tailscale'),
  );
  final session = SessionController(
    connectivity: connectivity,
    tunnelConnect: tunnel.connect,
    uploadPortFor: tunnel.uploadPortFor,
    catalogCacheFor: (account) => CatalogCache(
      file: File('${supportDir.path}/catalog/responses/$account.json'),
    ),
    outboxFor: (account) =>
        Outbox(File('${supportDir.path}/catalog/outbox/$account.json')),
  );
  final audioPlayer = AudioPlayer();
  final audioHandler = await AudioService.init(
    builder: () => YomiAudioHandler(audioPlayer),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.yomi.yomi.playback',
      androidNotificationChannelName: 'Yomi playback',
      androidNotificationOngoing: true,
    ),
  );
  final player = PlayerController(
    audioPlayer,
    cache: cache,
    downloads: downloads,
    settings: settings,
    connectivity: connectivity,
  );
  await session.restoreSaved();
  session.startMonitoring();
  audioHandler.commands = player;
  player.onStalled = () => unawaited(session.checkServer());
  final listeningDir = '${supportDir.path}/listening';
  File historyFile(String account) =>
      File('$listeningDir/history-$account.json');
  final legacyHistory = File('$listeningDir/history.json');
  final history = PlayHistory(legacyHistory);
  final scrobbles = ScrobbleQueue(File('$listeningDir/scrobbles.json'));
  var historyAccount = session.accountId;
  await history.openFor(
    historyAccount == null ? legacyHistory : historyFile(historyAccount),
    legacy: historyAccount == null ? null : legacyHistory,
  );
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
  final listeningLog = ListeningLog(
    directory: Directory(listeningDir),
    history: history,
  );
  final ai = AiController(file: File('$listeningDir/ai-labels.json'));
  await ai.load();
  final imports = ImportsController(
    file: File('$listeningDir/imported-playlists.json'),
  );
  await imports.load();
  late final CatalogController catalog;
  final keeper = OfflineKeeper(
    downloads: downloads,
    ledger: ledger,
    settings: settings,
    connectivity: connectivity,
    history: history,
    cache: cache,
    currentSong: () => player.current,
    importedSongs: () => imports.songsIn(catalog.songs),
  );
  catalog = CatalogController(
    directory: Directory('${supportDir.path}/catalog/songs'),
  );
  final home = HomeController(
    history: history,
    settings: settings,
    cacheFile: File('$listeningDir/home.json'),
    catalogSongs: () => catalog.songs,
    moodsFor: (songs) => {
      for (final entry in ai.tagsById(songs).entries)
        entry.key: entry.value.moods,
    },
    similarArtists: () => ai.similarArtists,
    otherDevicePlays: () => listeningLog.remotePlays,
    importedTaste: () => listeningLog.imported.artistTaste,
    pastFavouritesFor: (songs) => pastFavourites(listeningLog.imported, songs),
  );
  await home.loadCache();
  player.suggestNext = () =>
      [for (final shelf in home.shelves) ...shelf.songs]
          .take(_suggestedSongsPerSkip)
          .toList();
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
  final messages = MessagesController(
    savedChats: Directory('${supportDir.path}/chats'),
    me: () => session.username,
    listenForEvents: true,
  );
  String? sharedSongId;
  void sharePlaying() {
    final song = settings.shareListening ? player.current : null;
    if (song?.id == sharedSongId) return;
    sharedSongId = song?.id;
    unawaited(
      messages.sharePlaying(
        songId: song?.id,
        title: song?.title,
        artist: song?.artist,
      ),
    );
  }

  player.addListener(sharePlaying);
  settings.addListener(sharePlaying);
  String? messagingUrl;
  void publishProfile() => unawaited(
    messages.publishProfile(
      displayName: profile.nickname,
      bio: profile.bio,
      avatar: profile.avatarFile,
    ),
  );
  profile.addListener(publishProfile);
  var wasReachable = false;
  String? aiUrl;
  void followSession() {
    final client = session.isSignedIn ? session.client : null;
    player.attach(client);
    downloads.attach(client);
    listening.attach(client);
    final account = session.accountId;
    if (account != historyAccount) {
      final wasSignedIn = historyAccount != null;
      historyAccount = account;
      unawaited(
        account == null
            ? history.clear()
            : history.openFor(
                historyFile(account),
                legacy: wasSignedIn ? null : legacyHistory,
              ),
      );
    }
    home.attach(client);
    unawaited(_followCatalog(catalog, client, session.accountId));
    keeper.attach(client, session.username);
    if (client == null) {
      ai.attach(null);
    } else if (client.baseUrl != aiUrl) {
      ai.attach(
        AiApi(
          serverUrl: client.baseUrl,
          auth: client,
          port: session.uploadServicePort,
        ),
      );
    }
    if (client == null) {
      unawaited(imports.attach(null));
    } else if (client.baseUrl != aiUrl) {
      unawaited(
        imports.attach(
          ImportsApi(
            serverUrl: client.baseUrl,
            auth: client,
            port: session.uploadServicePort,
          ),
        ),
      );
    }
    if (client == null) {
      unawaited(listeningLog.attach(null, null));
    } else if (client.baseUrl != aiUrl) {
      final api = HistoryApi(
        serverUrl: client.baseUrl,
        auth: client,
        port: session.uploadServicePort,
      );
      unawaited(
        listeningLog
            .attach(api, account)
            .then((_) => listeningLog.sync())
            .then((_) => home.refreshIfDue()),
      );
    }
    aiUrl = client?.baseUrl;
    final isReachable = session.isServerReachable;
    player.isServerDown = !isReachable;
    if (client != null && isReachable && !wasReachable) {
      unawaited(client.flushOutbox());
      unawaited(messages.flushPending());
    }
    wasReachable = isReachable;
    if (client == null) {
      messages.attach(null);
    } else if (client.baseUrl != messagingUrl) {
      messagingUrl = client.baseUrl;
      messages.attach(session.messaging);
      publishProfile();
    }
    uploads.attach(
      client == null ? null : session.uploader,
      loadSnapshot: client == null ? null : snapshotLoaderFor(client),
    );
    sync.attach(client);
  }

  catalog.addListener(() {
    if (catalog.isLoaded) {
      unawaited(ai.queueMissing(catalog.songs));
      unawaited(imports.rematch(catalog.songs));
    }
  });
  session.addListener(followSession);
  followSession();

  // Older versions kept these in preferences, where they could never be read again.
  for (final key in prefs.getKeys().toList()) {
    if (key.startsWith('catalog_v1_') || key.startsWith('song_count_')) {
      await prefs.remove(key);
    }
  }
  final updates = await _buildUpdateController(prefs);
  DateTime? hiddenSince;
  AppLifecycleListener(
    onHide: () => hiddenSince = DateTime.now(),
    onResume: () {
      final since = hiddenSince;
      if (since != null &&
          DateTime.now().difference(since) > _showNewHomeAfter) {
        home.applyHeldBack();
      }
      unawaited(updates.check());
      unawaited(home.refreshIfDue());
      unawaited(catalog.sync());
      unawaited(keeper.run());
      unawaited(ai.refresh());
      unawaited(listeningLog.sync());
      unawaited(imports.sync());
      unawaited(messages.refresh());
    },
  );

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
      home: home,
      catalog: catalog,
      keeper: keeper,
      ai: ai,
      listeningLog: listeningLog,
      imports: imports,
      tunnel: tunnel,
      messages: messages,
    ),
  );
  unawaited(updates.check());
  unawaited(session.resolveRoute());
  await runDevHooks(session, player);
}

/// Follows the signed-in account, then brings its saved songs up to date.
const int _suggestedSongsPerSkip = 20;

/// How long the app must be away before a prepared Home replaces the one showing.
const Duration _showNewHomeAfter = Duration(minutes: 30);

Future<void> _followCatalog(
  CatalogController catalog,
  SubsonicClient? client,
  String? accountId,
) async {
  await catalog.attach(client, accountId);
  if (client != null) await catalog.sync();
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
    required this.home,
    required this.catalog,
    required this.keeper,
    required this.ai,
    required this.listeningLog,
    required this.imports,
    required this.tunnel,
    required this.messages,
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
  final HomeController home;
  final CatalogController catalog;
  final OfflineKeeper keeper;
  final AiController ai;
  final ListeningLog listeningLog;
  final ImportsController imports;
  final TunnelController tunnel;
  final MessagesController messages;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<UpdateController>.value(value: updates),
        ChangeNotifierProvider<UploadQueue>.value(value: uploads),
        ChangeNotifierProvider<MessagesController>.value(value: messages),
        ChangeNotifierProvider<TunnelController>.value(value: tunnel),
        ChangeNotifierProvider<HomeController>.value(value: home),
        ChangeNotifierProvider<CatalogController>.value(value: catalog),
        ChangeNotifierProvider<OfflineKeeper>.value(value: keeper),
        ChangeNotifierProvider<AiController>.value(value: ai),
        ChangeNotifierProvider<ListeningLog>.value(value: listeningLog),
        ChangeNotifierProvider<ImportsController>.value(value: imports),
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
