import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/offline/download_store.dart';
import '../core/offline/file_fetcher.dart';
import '../core/subsonic_client.dart';
import 'connectivity_controller.dart';
import 'settings.dart';

enum DownloadStatus { none, queued, downloading, done, failed }

typedef CoverWarmer = Future<void> Function(SubsonicClient client, Song song);

/// Saves songs for offline play, one at a time so the little server is never overloaded.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.store,
    required this.settings,
    required this.connectivity,
    this.fetcher = const FileFetcher(),
    this.warmCover,
  }) {
    connectivity.addListener(_pump);
    settings.addListener(_pump);
  }

  final DownloadStore store;
  final SettingsController settings;
  final ConnectivityController connectivity;
  final FileFetcher fetcher;
  final CoverWarmer? warmCover;

  SubsonicClient? _client;
  final List<Song> _queue = [];
  final Set<String> _failed = {};
  final Map<String, double> _progress = {};
  String? _activeId;
  CancelToken? _cancel;
  bool _isPumping = false;

  void attach(SubsonicClient? client) {
    _client = client;
    if (client == null) cancelAll();
    _pump();
  }

  List<Song> get downloadedSongs => store.songs;
  int get downloadedBytes => store.totalBytes;
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

  void enqueue(Iterable<Song> songs) {
    for (final song in songs) {
      if (store.contains(song.id) ||
          _activeId == song.id ||
          _queue.any((s) => s.id == song.id))
        continue;
      _failed.remove(song.id);
      _queue.add(song);
    }
    notifyListeners();
    _pump();
  }

  Future<void> remove(Song song) async {
    _queue.removeWhere((s) => s.id == song.id);
    if (_activeId == song.id) _cancel?.cancel();
    await store.remove(song.id);
    _progress.remove(song.id);
    notifyListeners();
  }

  Future<void> removeAll() async {
    cancelAll();
    await store.removeAll();
    notifyListeners();
  }

  void cancelAll() {
    _queue.clear();
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
              _progress[song.id] = p;
              notifyListeners();
            },
          );
          await store.add(song, fetched);
          await warmCover?.call(_client!, song);
        } on FetchCancelled {
          // removed or cancelled by the user
        } on Exception catch (error) {
          debugPrint('Download of ${song.title} failed: $error');
          _failed.add(song.id);
        } finally {
          _queue.removeWhere((s) => s.id == song.id);
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
