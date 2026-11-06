import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/listening/auto_download_ledger.dart';
import '../core/models.dart';
import '../core/offline/download_store.dart';
import '../core/offline/file_fetcher.dart';
import '../core/subsonic_client.dart';
import 'connectivity_controller.dart';
import 'settings.dart';

enum DownloadStatus {
  none,
  queued,
  downloading,
  done,
  failed;

  /// Whether the song is saved or on its way, so the action offered is "Remove".
  /// A failed download isn't saved: it offers "Download" again.
  bool get isSavedOrSaving =>
      this == done || this == queued || this == downloading;
}

typedef CoverWarmer = Future<void> Function(SubsonicClient client, Song song);

/// Saves songs for offline play, one at a time so the little server is never overloaded.
/// Screens hear about download progress this many times per song.
const int _progressSteps = 20;

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.store,
    required this.settings,
    required this.connectivity,
    this.fetcher = const FileFetcher(),
    this.warmCover,
    this.ledger,
    File? queueFile,
    this.onSaved,
  }) : _queueFile = queueFile {
    connectivity.addListener(_pump);
    settings.addListener(_pump);
  }

  final DownloadStore store;
  final SettingsController settings;
  final ConnectivityController connectivity;
  final FileFetcher fetcher;
  final CoverWarmer? warmCover;
  final AutoDownloadLedger? ledger;

  /// Told once a song is saved, so a streamed or cached copy can be removed.
  final Future<void> Function(String songId)? onSaved;
  final File? _queueFile;
  Future<void> _queueWrites = Future.value();

  SubsonicClient? _client;
  final List<Song> _queue = [];
  final Set<String> _failed = {};
  final Map<String, double> _progress = {};
  String? _activeId;
  CancelToken? _cancel;
  bool _isPumping = false;

  /// Picks up downloads that were still waiting when the app last closed.
  Future<void> loadQueue() async {
    final file = _queueFile;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as List<dynamic>;
      final known = {for (final song in _queue) song.id};
      _queue.addAll(
        json
            .cast<Map<String, dynamic>>()
            .map(Song.fromJson)
            .where((s) => !store.contains(s.id) && !known.contains(s.id)),
      );
      notifyListeners();
      unawaited(_pump());
    } on Object catch (error) {
      debugPrint('Ignoring an unreadable download queue: $error');
    }
  }

  void _saveQueue() {
    final file = _queueFile;
    if (file == null) return;
    final snapshot = [for (final song in _queue) song.toJson()];
    _queueWrites = _queueWrites.then((_) async {
      try {
        final temp = File('${file.path}.tmp');
        await temp.parent.create(recursive: true);
        await temp.writeAsString(jsonEncode(snapshot));
        await temp.rename(file.path);
      } on Object catch (error) {
        debugPrint('Could not save the download queue: $error');
      }
    });
  }

  void attach(SubsonicClient? client) {
    _client = client;
    if (client == null) cancelAll();
    _pump();
  }

  List<Song> get downloadedSongs => store.songs;
  int get downloadedBytes => store.totalBytes;
  int bytesOf(String songId) => store.bytesOf(songId);
  int get pendingCount => _queue.length;
  bool isDownloaded(String songId) => store.contains(songId);
  File? localFile(String songId) => store.fileFor(songId);
  double progressOf(String songId) => _progress[songId] ?? 0;

  /// Why the queue is waiting, if it is.
  String? get pausedReason {
    if (_queue.isEmpty) return null;
    if (connectivity.isOffline) return 'Waiting for a connection';
    if (settings.wifiOnlyDownloads && !connectivity.isOnWifi)
      return 'Waiting for Wi-Fi';
    return null;
  }

  DownloadStatus statusOf(String songId) {
    if (store.contains(songId)) return DownloadStatus.done;
    if (_activeId == songId) return DownloadStatus.downloading;
    if (_queue.any((s) => s.id == songId)) return DownloadStatus.queued;
    if (_failed.contains(songId)) return DownloadStatus.failed;
    return DownloadStatus.none;
  }

  /// How many of [songs] are saved, for album/playlist buttons.
  int downloadedCountOf(Iterable<Song> songs) =>
      songs.where((s) => store.contains(s.id)).length;

  /// Songs queued with [isAuto] may be evicted later. Everything else was the
  /// user's own choice, even if Yomi had already saved it automatically.
  void enqueue(Iterable<Song> songs, {bool isAuto = false}) {
    for (final song in songs) {
      if (!isAuto) ledger?.markManual(song.id);
      if (store.contains(song.id) ||
          _activeId == song.id ||
          _queue.any((s) => s.id == song.id))
        continue;
      _failed.remove(song.id);
      _queue.add(song);
    }
    _saveQueue();
    notifyListeners();
    _pump();
  }

  /// Drops an automatic download to make room. Unlike [remove], this isn't the
  /// user saying they don't want the song.
  Future<void> evict(String songId) async {
    await store.remove(songId);
    notifyListeners();
  }

  Future<void> remove(Song song) async {
    ledger?.markUserRemoved(song.id);
    _queue.removeWhere((s) => s.id == song.id);
    _saveQueue();
    if (_activeId == song.id) _cancel?.cancel();
    await store.remove(song.id);
    _progress.remove(song.id);
    notifyListeners();
  }

  Future<void> removeAll() async {
    for (final id in ledger?.autoIds.toList() ?? const <String>[]) {
      ledger?.markUserRemoved(id);
    }
    cancelAll();
    await store.removeAll();
    notifyListeners();
  }

  void cancelAll() {
    _queue.clear();
    _saveQueue();
    _cancel?.cancel();
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_isPumping || _client == null) return;
    _isPumping = true;
    try {
      while (_queue.isNotEmpty && pausedReason == null && _client != null) {
        final song = _queue.first;
        _activeId = song.id;
        _cancel = CancelToken();
        _progress[song.id] = 0;
        notifyListeners();
        try {
          final fetched = await fetcher.fetch(
            _client!.downloadUri(song.id),
            store.baseFor(song.id),
            cancel: _cancel,
            onProgress: (p) {
              final previous = _progress[song.id] ?? 0;
              _progress[song.id] = p;
              // Rebuilding on every chunk slows the whole screen, and nobody needs it.
              if ((p * _progressSteps).floor() !=
                  (previous * _progressSteps).floor()) {
                notifyListeners();
              }
            },
          );
          await store.add(song, fetched);
          await onSaved?.call(song.id);
          await warmCover?.call(_client!, song);
        } on FetchCancelled {
          // removed or cancelled by the user
        } on Exception catch (error) {
          debugPrint('Download of ${song.title} failed: $error');
          _failed.add(song.id);
        } finally {
          _queue.removeWhere((s) => s.id == song.id);
          _saveQueue();
          _activeId = null;
          _cancel = null;
          _progress.remove(song.id);
          notifyListeners();
        }
      }
    } finally {
      _isPumping = false;
    }
  }

  @override
  void dispose() {
    connectivity.removeListener(_pump);
    settings.removeListener(_pump);
    super.dispose();
  }
}
