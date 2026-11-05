import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/listening/auto_download_ledger.dart';
import '../core/listening/play_history.dart';
import '../core/models.dart';
import '../core/offline/audio_cache.dart';
import '../core/offline/storage_plan.dart';
import '../core/subsonic_client.dart';
import 'connectivity_controller.dart';
import 'download_manager.dart';
import 'settings.dart';

/// A rough guess at a song's size before it's downloaded: about 320 kbps.
const int _estimatedBytesPerSecond = 40000;

/// The song cache always keeps at least this, so playback stays smooth at the limit.
const int _minCacheBytes = 256 * 1024 * 1024;

/// How far along a playlist's offline copy is.
@immutable
class PlaylistOfflineStatus {
  const PlaylistOfflineStatus({
    required this.saved,
    required this.total,
    required this.isLimited,
  });

  final int saved;
  final int total;

  /// The storage limit, rather than time, is what's keeping this incomplete.
  final bool isLimited;
}

/// Keeps your playlists on the device within the storage limit, on Wi-Fi.
class OfflineKeeper extends ChangeNotifier {
  OfflineKeeper({
    required this.downloads,
    required this.ledger,
    required this.settings,
    required this.connectivity,
    required this.history,
    required this.cache,
    required this.currentSong,
    this.importedSongs,
    this.isLibraryReady,
  }) {
    _settingsSeen = _settingsThatMatter();
    connectivity.addListener(_onConditionsChanged);
    settings.addListener(_onSettingsChanged);
  }

  final DownloadManager downloads;
  final AutoDownloadLedger ledger;
  final SettingsController settings;
  final ConnectivityController connectivity;
  final PlayHistory history;
  final AudioCache cache;
  final Song? Function() currentSong;

  /// Songs in imported playlists, which are kept along with your own.
  final List<Song> Function()? importedSongs;

  /// False while the library is still loading, when imported songs merely look missing.
  final bool Function()? isLibraryReady;
  late Object _settingsSeen;

  SubsonicClient? _client;
  String _username = '';
  StreamSubscription<String>? _updates;
  Map<String, List<Song>> _kept = const {};
  bool _isLimited = false;
  Future<void>? _active;
  bool _runAgain = false;

  void attach(SubsonicClient? client, String username) {
    final isSame = identical(client, _client);
    _client = client;
    _username = username;
    if (isSame) return;
    unawaited(_updates?.cancel());
    _updates = client?.catalogUpdates.listen((endpoint) {
      if (endpoint == 'getPlaylists') unawaited(run());
    });
    if (client == null) {
      _kept = const {};
      _isLimited = false;
      notifyListeners();
    } else {
      unawaited(run());
    }
  }

  void _onConditionsChanged() => unawaited(run());

  /// Only what affects saved songs. Settings tell everyone about every change, and a
  /// reordered Home shouldn't make the server list every playlist again.
  String _settingsThatMatter() =>
      '${settings.keepPlaylistsOffline}|${settings.storageLimitBytes}|'
      '${settings.wifiOnlyDownloads}|${settings.playlistKeepChoices}';

  void _onSettingsChanged() {
    final current = _settingsThatMatter();
    if (current == _settingsSeen) return;
    _settingsSeen = current;
    unawaited(run());
  }

  /// Whether this playlist is one Yomi keeps by itself: your own, unless you've said not.
  bool isKept(Playlist playlist) {
    if (!settings.keepPlaylistsOffline) return false;
    return settings.playlistKeepChoice(playlist.id) ??
        (playlist.owner == null || playlist.owner == _username);
  }

  Future<void> setKept(Playlist playlist, bool value) async {
    await settings.setPlaylistKeepChoice(playlist.id, value);
  }

  PlaylistOfflineStatus? statusOf(String playlistId) {
    final songs = _kept[playlistId];
    if (songs == null) return null;
    final saved = downloads.downloadedCountOf(songs);
    return PlaylistOfflineStatus(
      saved: saved,
      total: songs.length,
      isLimited: _isLimited && saved < songs.length,
    );
  }

  /// Brings the saved copies in line with your playlists and the limit. Safe to call any
  /// time: conditions that aren't right simply leave everything as it is.
  Future<void> run() {
    final active = _active;
    if (active != null) {
      _runAgain = true;
      return active;
    }
    return _active = _runUntilDone().whenComplete(() => _active = null);
  }

  Future<void> _runUntilDone() async {
    try {
      do {
        _runAgain = false;
        await _runOnce();
      } while (_runAgain);
    } on Object catch (error) {
      debugPrint('Could not update offline playlists: $error');
    }
  }

  Future<void> _runOnce() async {
    final client = _client;
    if (client != null && connectivity.isOnWifi) {
      final playlists = await client.playlists();
      final kept = <String, List<Song>>{};
      for (final playlist in playlists.where(isKept)) {
        kept[playlist.id] = await client.playlistSongs(playlist.id);
      }
      if (!identical(client, _client)) return;
      _kept = Map.unmodifiable(kept);
      await _applyPlan();
    }
    _updateCacheLimit();
    notifyListeners();
  }

  Future<void> _applyPlan() async {
    final songs = <String, Song>{
      for (final list in _kept.values)
        for (final song in list) song.id: song,
      if (settings.keepPlaylistsOffline)
        for (final song in importedSongs?.call() ?? const <Song>[])
          song.id: song,
    };
    final isReady = isLibraryReady?.call() ?? true;
    final isManual = {
      for (final id in songs.keys)
        if (downloads.isDownloaded(id) && !ledger.isKept(id)) id,
    };
    final candidates = <KeepCandidate>[
      for (final song in songs.values)
        if (!isManual.contains(song.id) && !ledger.isDeclined(song.id))
          KeepCandidate(
            id: song.id,
            bytes: downloads.isDownloaded(song.id)
                ? downloads.bytesOf(song.id)
                : song.durationSeconds * _estimatedBytesPerSecond,
            isSaved: downloads.isDownloaded(song.id),
            lastPlayed: history.lastPlayed(song.id),
          ),
    ];
    final playing = currentSong()?.id;
    final plan = planKeptSongs(
      capBytes: settings.storageLimitBytes,
      wanted: candidates,
      // Nothing counts as unwanted until the library has loaded and can really say.
      unwanted: [
        if (isReady)
          for (final id in ledger.keptIds)
            if (!songs.containsKey(id) && downloads.isDownloaded(id)) id,
      ],
      protect: {?playing},
    );
    _isLimited = plan.isLimited;
    for (final id in plan.evict) {
      ledger.markEvicted(id, DateTime.now());
      await downloads.evict(id);
    }
    final fetch = [
      for (final id in plan.fetch)
        if (downloads.statusOf(id) == DownloadStatus.none ||
            downloads.statusOf(id) == DownloadStatus.failed)
          songs[id]!,
    ];
    if (fetch.isEmpty) return;
    for (final song in fetch) {
      ledger.markKept(song.id);
    }
    downloads.enqueue(fetch, isAuto: true);
  }

  /// The song cache gets whatever the saved songs leave free.
  void _updateCacheLimit() {
    final savedAuto = ledger.autoIds.fold<int>(
      0,
      (sum, id) => sum + downloads.bytesOf(id),
    );
    cache.maxBytes = max(
      _minCacheBytes,
      settings.storageLimitBytes - savedAuto,
    );
  }

  @override
  void dispose() {
    connectivity.removeListener(_onConditionsChanged);
    settings.removeListener(_onSettingsChanged);
    unawaited(_updates?.cancel());
    super.dispose();
  }
}
