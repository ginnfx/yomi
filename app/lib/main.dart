import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/mixes.dart';
import 'core/ai/ai_api.dart';
import 'core/apk_installer.dart';
import 'core/app_info.dart';
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
import 'core/cover_crop.dart';
import 'core/cover_prefiller.dart';
import 'core/cover_sizes.dart';
import 'core/offline/cover_warmer.dart';
import 'core/offline/download_store.dart';
import 'core/offline/outbox.dart';
import 'core/spotify/imported_playlist.dart';
import 'core/models.dart';
import 'core/radio.dart';
import 'core/reports/reports_api.dart';
import 'core/spotify/missing_songs.dart';
import 'core/tunnel/ffi_tunnel_bridge.dart';
import 'core/youtube/youtube_fetcher.dart';
import 'core/subsonic_client.dart';
import 'dev_hooks.dart';
import 'state/appearance_controller.dart';
import 'state/connectivity_controller.dart';
import 'state/download_manager.dart';
import 'state/ai_controller.dart';
import 'state/assistant_controller.dart';
import 'state/catalog_controller.dart';
import 'state/home_controller.dart';
import 'state/imports_controller.dart';
import 'state/offline_keeper.dart';
import 'state/listening_controller.dart';
import 'state/listening_log.dart';
import 'state/messages_controller.dart';
import 'state/player_controller.dart';
import 'state/playlist_covers_controller.dart';
import 'state/playback_sync_controller.dart';
import 'state/profile_controller.dart';
import 'state/reports_controller.dart';
import 'state/session.dart';
import 'state/youtube_controller.dart';
import 'state/settings.dart';
import 'state/tunnel_controller.dart';
import 'state/update_controller.dart';
import 'state/upload_queue.dart';
import 'ui/widgets/album_card.dart' show kCardWidth;
import 'ui/pages/login_page.dart';
import 'ui/appearance_scope.dart';
import 'ui/pages/shell_page.dart';
import 'ui/theme.dart';
import 'ui/widgets/desktop_controls.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

/// Computers get the quicker handoff polling and the background caching phones skip.
final bool _isDesktop = Platform.isMacOS || Platform.isLinux;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux) _prepareLinux();
  // Before any server request, so each one says which version is asking.
  appInfo = await _loadAppInfo();

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
    bridge: tunnelBridgeForThisDevice(),
    prefs: prefs,
    stateDir: Directory('${supportDir.path}/tailscale'),
  );
  final session = SessionController(
    connectivity: connectivity,
    tunnelConnect: tunnel.connect,
    tunnelReconnect: tunnel.reconnect,
    tunnelNetworkChanged: tunnel.networkChanged,
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
  final playlistCovers = PlaylistCoversController();
  final reports = ReportsController(prefs);
  late final CatalogController catalogForAi;
  late final HomeController homeForAi;
  TasteSummary tasteSummary() => (
    topArtists: topArtistsOf(homeForAi.taste),
    moods: topMoodsOf(
      library: catalogForAi.songs,
      taste: homeForAi.taste,
      tagFor: ai.tagFor,
    ),
  );
  final assistant = AssistantController(
    index: () => catalogForAi.searchIndex,
    taste: tasteSummary,
  );
  final discover = DiscoverController(
    prefs,
    index: () => catalogForAi.searchIndex,
    taste: tasteSummary,
  );
  final youtube = YoutubeFetcher(
    ytDlp: ytDlpForThisDevice(supportDir),
    cacheDir: Directory(
      '${(await getApplicationCacheDirectory()).path}/youtube',
    ),
  );
  final imports = ImportsController(
    file: File('$listeningDir/imported-playlists.json'),
  );
  await imports.load();
  // Songs an import couldn't find go on the server's to-add list, once each.
  void requestMissingSongs() =>
      unawaited(reports.requestMissing(missingFromImports(imports.playlists)));
  imports.addListener(requestMissingSongs);
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
    isLibraryReady: () => catalog.isLoaded,
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
    libraryVersion: () => catalog.lastScan,
  );
  await home.loadCache();
  catalogForAi = catalog;
  homeForAi = home;
  WidgetsBinding.instance.addObserver(_CoverMemoryObserver());
  await CoverImageService.instance.warm(
    _coversOnFirstScreen(home),
    limit: _coverWarmLimit,
  );
  // When the queue runs out: songs like the last one, else what Home suggests.
  // The player asks often while building, so the radio is kept per song.
  (Object, List<Song>)? radioMemo;
  player.suggestNext = () {
    final seed = player.current;
    if (seed != null) {
      final memoKey = (seed.id, catalog.songs, ai.labelledCount);
      final memo = radioMemo;
      final radio = memo != null && memo.$1 == memoKey
          ? memo.$2
          : radioFrom(
              seed,
              library: catalog.songs,
              tagFor: ai.tagFor,
              similarArtists: ai.similarArtists,
            );
      radioMemo = (memoKey, radio);
      if (radio.isNotEmpty) return radio.take(_suggestedSongsPerSkip).toList();
    }
    return [for (final shelf in home.shelves) ...shelf.songs]
        .take(_suggestedSongsPerSkip)
        .toList();
  };
  final uploadsDir = '${supportDir.path}/uploads';
  final uploads = UploadQueue(
    queueFile: File('$uploadsDir/queue.json'),
    hashCacheFile: File('$uploadsDir/hashes.json'),
  );
  await uploads.load();
  final youtubeSongs = YoutubeController(
    fetcher: youtube,
    saveDir: Directory('$uploadsDir/youtube'),
    startPlaying: (song, file) async {
      player.registerExternalFile(song, file);
      await player.playQueue([song]);
    },
    upload: (path) async => uploads.addFiles([path]),
    onSaved: reports.markAddedMatching,
  );
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
    pollInterval: Duration(seconds: _isDesktop ? 2 : 5),
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
  // Friends see your top artists and moods, never single plays, and only while you
  // share what you're listening to.
  void shareTaste() {
    final isSharing = settings.shareListening;
    final taste = home.taste;
    unawaited(
      messages.shareTaste(
        topArtists: isSharing ? topArtistsOf(taste) : const [],
        topMoods: isSharing
            ? topMoodsOf(
                library: catalog.songs,
                taste: taste,
                tagFor: ai.tagFor,
              )
            : const [],
      ),
    );
  }

  home.addListener(shareTaste);
  settings.addListener(shareTaste);
  String? messagingUrl;
  void publishProfile() {
    if (!profile.hasContent) return;
    unawaited(
      messages.publishProfile(
        displayName: profile.nickname,
        bio: profile.bio,
        avatar: profile.avatarFile,
      ),
    );
  }

  // After signing back in, take the name and bio from the server, as signing out cleared
  // them here. Only once, and only if nothing's been typed in the meantime.
  var needsProfileFromServer = !profile.hasContent;
  messages.addListener(() {
    if (!needsProfileFromServer || messages.people.isEmpty) return;
    needsProfileFromServer = false;
    final mine = messages.profileOf(session.username);
    if (profile.hasContent) return;
    if (mine.displayName.isNotEmpty)
      unawaited(profile.setNickname(mine.displayName));
    if (mine.bio.isNotEmpty) unawaited(profile.setBio(mine.bio));
  });
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
      if (account == null && wasSignedIn) {
        // What belongs to the person leaving mustn't reach whoever signs in next.
        unawaited(scrobbles.clear());
        unawaited(profile.clear());
        unawaited(settings.clearPersonal());
        needsProfileFromServer = true;
      }
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
      assistant.attach(null);
      discover.attach(null);
    } else if (client.baseUrl != aiUrl) {
      final aiApi = AiApi(
        serverUrl: client.baseUrl,
        auth: client,
        port: session.uploadServicePort,
      );
      ai.attach(aiApi);
      assistant.attach(aiApi);
      discover.attach(aiApi);
    }
    if (client == null) {
      playlistCovers.attach(null);
    } else if (client.baseUrl != aiUrl) {
      playlistCovers.attach(
        PlaylistCoversApi(
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
    if (client == null) {
      reports.attach(null);
    } else if (client.baseUrl != aiUrl) {
      reports.attach(
        ReportsApi(
          serverUrl: client.baseUrl,
          auth: client,
          port: session.uploadServicePort,
        ),
      );
      unawaited(reports.refresh());
      requestMissingSongs();
    }
    final addressChanged = client != null && client.baseUrl != aiUrl;
    aiUrl = client?.baseUrl;
    final isReachable = session.isServerReachable;
    // Covers still loading may be stuck on an address that no longer works.
    if (client != null && (addressChanged || (isReachable && !wasReachable))) {
      CoverImageService.instance.retryFailed();
    }
    player.isServerDown = !isReachable;
    if (client != null && isReachable && !wasReachable) {
      unawaited(client.flushOutbox());
      unawaited(messages.flushPending());
    }
    wasReachable = isReachable;
    if (client == null) {
      messages.attach(null);
      messagingUrl = null;
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

  var wasCatalogLoaded = false;
  catalog.addListener(() {
    unawaited(home.refreshIfDue());
    if (catalog.isLoaded) {
      unawaited(ai.queueMissing(catalog.songs));
      unawaited(imports.rematch(catalog.songs));
      // Imported songs only count as kept once the library that holds them has loaded.
      if (!wasCatalogLoaded) unawaited(keeper.run());
    }
    wasCatalogLoaded = catalog.isLoaded;
  });
  session.addListener(followSession);
  followSession();

  var isInForeground = true;
  final coverPrefiller = CoverPrefiller(
    source: CoverImageService.instance.source,
    songs: () => catalog.songs,
    canRun: () =>
        isInForeground &&
        catalog.isLoaded &&
        connectivity.isOnWifi &&
        session.isSignedIn &&
        session.isServerReachable,
    urlFor: (id) => session.isSignedIn
        ? session.client.coverArtUri(id, size: smallCoverPx).toString()
        : null,
  );
  void wakeCoverPrefiller() => unawaited(coverPrefiller.wake());
  catalog.addListener(wakeCoverPrefiller);
  session.addListener(wakeCoverPrefiller);
  connectivity.addListener(wakeCoverPrefiller);
  wakeCoverPrefiller();

  // Older versions kept these in preferences, where they could never be read again.
  for (final key in prefs.getKeys().toList()) {
    if (key.startsWith('catalog_v1_') || key.startsWith('song_count_')) {
      await prefs.remove(key);
    }
  }
  final updates = await _buildUpdateController(prefs);
  DateTime? hiddenSince;
  AppLifecycleListener(
    onHide: () {
      hiddenSince = DateTime.now();
      isInForeground = false;
    },
    onResume: () {
      isInForeground = true;
      wakeCoverPrefiller();
      final since = hiddenSince;
      if (since != null &&
          DateTime.now().difference(since) > _showNewHomeAfter) {
        home.appOpened();
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
      reports: reports,
      youtubeSongs: youtubeSongs,
      assistant: assistant,
      discover: discover,
      playlistCovers: playlistCovers,
      tunnel: tunnel,
      messages: messages,
    ),
  );
  unawaited(updates.check());
  unawaited(session.resolveRoute());
  await runDevHooks(session, player);
  unawaited(runYoutubeSpike(youtube));
}

/// Follows the signed-in account, then brings its saved songs up to date.
const int _suggestedSongsPerSkip = 20;

/// How long the app must be away before a prepared Home replaces the one showing.
const Duration _showNewHomeAfter = Duration(minutes: 30);

/// How long the first screen may wait for its covers before showing anyway.
const Duration _coverWarmLimit = Duration(milliseconds: 300);

/// Enough shelves to fill the first screen of Home.
const int _shelvesOnFirstScreen = 3;

/// Tiles visible across a shelf before you scroll it.
const int _tilesOnFirstScreen = 4;

/// The size of the tiles at the top of Home.
const double _quickTile = 60;

/// The covers the first screen of Home will ask for: small tiles at the top, and larger
/// cards on the shelves below.
Iterable<String> _coversOnFirstScreen(HomeController home) sync* {
  final tiles = [
    for (final playlist in home.quickPlaylists) playlist.coverArtId,
    for (final song in home.quickSongs) song.coverArtId,
  ];
  for (final cover in tiles) {
    if (cover != null) yield coverCacheKey(cover, coverPixelsFor(_quickTile));
  }
  for (final shelf in home.shelves.take(_shelvesOnFirstScreen)) {
    for (final song in shelf.songs.take(_tilesOnFirstScreen)) {
      final cover = song.coverArtId;
      if (cover != null) yield coverCacheKey(cover, coverPixelsFor(kCardWidth));
    }
  }
}

/// Frees decoded covers when the system asks, so playing in the background is less likely
/// to get the app closed.
class _CoverMemoryObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() => CoverImageService.instance.releaseMemory();
}

Future<void> _followCatalog(
  CatalogController catalog,
  SubsonicClient? client,
  String? accountId,
) async {
  await catalog.attach(client, accountId);
  if (client != null) await catalog.sync();
}

/// Linux has no built-in player or SQLite for the plugins Yomi uses: media_kit (libmpv)
/// plays audio and sqflite's FFI build backs the cover cache.
void _prepareLinux() {
  JustAudioMediaKit.ensureInitialized(linux: true, windows: false);
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// A broken version lookup must not stop the app from starting; it then just
/// shows no version.
Future<AppInfo> _loadAppInfo() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return AppInfo(
      version: info.version,
      buildNumber: info.buildNumber,
      platform: Platform.operatingSystem,
    );
  } on Exception catch (error) {
    debugPrint('Could not read the app version: $error');
    return AppInfo(platform: Platform.operatingSystem);
  }
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
  if (Platform.isMacOS || Platform.isLinux) return UpdateMode.openReleasePage;
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
    required this.reports,
    required this.youtubeSongs,
    required this.assistant,
    required this.discover,
    required this.playlistCovers,
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
  final ReportsController reports;
  final YoutubeController youtubeSongs;
  final AssistantController assistant;
  final DiscoverController discover;
  final PlaylistCoversController playlistCovers;
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
        ChangeNotifierProvider<ReportsController>.value(value: reports),
        ChangeNotifierProvider<YoutubeController>.value(value: youtubeSongs),
        ChangeNotifierProvider<AssistantController>.value(value: assistant),
        ChangeNotifierProvider<DiscoverController>.value(value: discover),
        ChangeNotifierProvider<PlaylistCoversController>.value(
          value: playlistCovers,
        ),
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
        ChangeNotifierProvider<PlayHistory>.value(value: history),
      ],
      child: Consumer<AppearanceController>(
        builder: (context, look, _) => MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'Yomi',
          debugShowCheckedModeBanner: false,
          theme: buildYomiTheme(look.palette, brightness: Brightness.light),
          darkTheme: buildYomiTheme(look.palette, trueBlack: look.isTrueBlack),
          themeMode: look.themeMode,
          // Wrapping the Navigator means every page, including pushed ones, reads the live accent.
          builder: (context, child) => AppearanceScope(
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
