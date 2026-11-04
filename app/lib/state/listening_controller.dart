import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/listening/auto_download_ledger.dart';
import '../core/listening/play_history.dart';
import '../core/listening/play_tracker.dart';
import '../core/listening/scrobble_queue.dart';
import '../core/models.dart';
import '../core/subsonic_client.dart';
import 'connectivity_controller.dart';
import 'download_manager.dart';
import 'settings.dart';

/// Full listens within [kRepeatWindow] that make a song worth keeping offline.
const int kRepeatPlays = 3;
const Duration kRepeatWindow = Duration(days: 14);
const int kAutoDownloadCapBytes = 2 * 1024 * 1024 * 1024;

/// Reports plays to the server, remembers them locally, and saves songs on repeat.
class ListeningController {
  ListeningController({
    required this.history,
    required this.scrobbles,
    required this.ledger,
    required this.downloads,
    required this.settings,
    required this.connectivity,
    required this.trackChanges,
    required this.currentSong,
    required this.isPlaying,
    required Stream<Duration> positions,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _tracker = PlayTracker(
      onStarted: _onStarted,
      onScrobble: _onScrobble,
      onCompleted: _onCompleted,
      onSkipped: _onSkipped,
    );
    trackChanges.addListener(_onTrackChange);
    connectivity.addListener(_onConnectivityChange);
    downloads.addListener(_enforceCap);
    _positions = positions.listen(
      (position) =>
          _tracker.position(position, isPlaying: isPlaying(), now: _now()),
    );
  }

  final PlayHistory history;
  final ScrobbleQueue scrobbles;
  final AutoDownloadLedger ledger;
  final DownloadManager downloads;
  final SettingsController settings;
  final ConnectivityController connectivity;
  final Listenable trackChanges;
  final Song? Function() currentSong;
  final bool Function() isPlaying;
  final DateTime Function() _now;
  late final PlayTracker _tracker;
  late final StreamSubscription<Duration> _positions;
  SubsonicClient? _client;
  bool _isEvicting = false;

  void attach(SubsonicClient? client) {
    _client = client;
    if (client != null) {
      unawaited(_flush());
      _queueRepeats();
    }
  }

  void _onTrackChange() => _tracker.trackChanged(currentSong(), _now());

  void _onConnectivityChange() {
    if (connectivity.isOffline) return;
    unawaited(_flush());
    _queueRepeats();
  }

  void _onStarted(Song song) {
    final client = _client;
    if (client == null || connectivity.isOffline) return;
    unawaited(
      client
          .scrobble(song.id, submission: false)
          .catchError(
            // Only affects "now playing" display, so there is nothing to retry.
            (Object error) => debugPrint('Now-playing update failed: $error'),
          ),
    );
  }

  void _onScrobble(Song song, DateTime startedAt) {
    unawaited(_submit(song, startedAt));
  }

  Future<void> _submit(Song song, DateTime startedAt) async {
    await scrobbles.add(PendingScrobble(song.id, startedAt));
    await _flush();
  }

  Future<void> _flush() async {
    final client = _client;
    if (client == null || connectivity.isOffline) return;
    await scrobbles.flush(client);
  }

  void _onCompleted(Song song, DateTime at) {
    unawaited(_recordCompleted(song, at));
  }

  Future<void> _recordCompleted(Song song, DateTime at) async {
    await history.record(song, PlayKind.completed, at);
    _queueRepeats();
  }

  void _onSkipped(Song song, DateTime at) {
    unawaited(history.record(song, PlayKind.skipped, at));
  }

  bool _qualifies(Song song) {
    if (downloads.isDownloaded(song.id) || ledger.isDeclined(song.id)) {
      return false;
    }
    final windowStart = _now().subtract(kRepeatWindow);
    final evictedAt = ledger.evictedAt(song.id);
    final since = evictedAt != null && evictedAt.isAfter(windowStart)
        ? evictedAt
        : windowStart;
    return history.fullPlaysSince(song.id, since) >= kRepeatPlays;
  }

  /// Runs after each play and when Wi-Fi returns, so a song that qualified on
  /// mobile data is fetched the next time it's cheap.
  void _queueRepeats() {
    if (!settings.autoDownloadRepeats || !connectivity.isOnWifi) return;
    if (_client == null) return;
    final due = history.songs.where(_qualifies).toList();
    if (due.isEmpty) return;
    for (final song in due) {
      ledger.markAuto(song.id);
    }
    downloads.enqueue(due, isAuto: true);
  }

  /// Evicts least recently played automatic downloads until they fit the cap.
  /// The song playing now is kept, even when it alone is over the cap.
  void _enforceCap() {
    if (_isEvicting) return;
    final saved = ledger.autoIds.where(downloads.isDownloaded).toList();
    var total = saved.fold<int>(0, (sum, id) => sum + downloads.bytesOf(id));
    if (total <= kAutoDownloadCapBytes) return;
    final playing = currentSong()?.id;
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final oldestFirst = saved.where((id) => id != playing).toList()
      ..sort(
        (a, b) => (history.lastPlayed(a) ?? epoch).compareTo(
          history.lastPlayed(b) ?? epoch,
        ),
      );
    _isEvicting = true;
    unawaited(() async {
      try {
        for (final id in oldestFirst) {
          if (total <= kAutoDownloadCapBytes) break;
          total -= downloads.bytesOf(id);
          ledger.markEvicted(id, _now());
          await downloads.evict(id);
        }
      } finally {
        _isEvicting = false;
      }
    }());
  }

  void dispose() {
    trackChanges.removeListener(_onTrackChange);
    connectivity.removeListener(_onConnectivityChange);
    downloads.removeListener(_enforceCap);
    unawaited(_positions.cancel());
  }
}
