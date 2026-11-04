import 'dart:async';

import '../models.dart';
import '../subsonic_client.dart';
import 'audio_cache.dart';
import 'file_fetcher.dart';

/// A replaceable, sequential warming plan. Files on disk are the source of
/// truth, so clearing or evicting the cache never prevents a future re-download.
class AudioPreloader {
  AudioPreloader({
    required this.cache,
    this.fetcher = const FileFetcher(),
    this.onCached,
    this.retryDelay = const Duration(seconds: 30),
  });

  final Duration retryDelay;
  final Map<String, DateTime> _retryAfter = {};
  final AudioCache cache;
  final FileFetcher fetcher;
  final Future<void> Function(Song song)? onCached;
  List<Song> _pending = [];
  Set<String> _wanted = {};
  Set<String> _protected = {};
  SubsonicClient? _client;
  CancelToken? _cancel;
  String? _inFlight;
  Future<void>? _work;
  bool _disposed = false;

  Future<void> get idle => _work ?? Future.value();

  void plan(
    SubsonicClient client,
    List<Song> songs, {
    Set<String> protect = const {},
  }) {
    if (_disposed) return;
    final accountChanged =
        _client != null && _client!.username != client.username;
    _client = client;
    _wanted = songs.map((s) => s.id).toSet();
    _protected = protect;
    if (accountChanged || (_inFlight != null && !_wanted.contains(_inFlight))) {
      _cancel?.cancel();
    }
    final seen = <String>{};
    _pending = songs
        .where(
          (s) =>
              seen.add(s.id) &&
              !cache.isCached(s.id) &&
              !(_retryAfter[s.id]?.isAfter(DateTime.now()) ?? false),
        )
        .toList();
    _start();
  }

  void _start() {
    if (_work != null || _disposed || _pending.isEmpty) return;
    _work = _run().whenComplete(() {
      _work = null;
      if (!_disposed && _pending.isNotEmpty) _start();
    });
  }

  Future<void> _run() async {
    while (!_disposed && _pending.isNotEmpty && _client != null) {
      final song = _pending.removeAt(0);
      if (cache.isCached(song.id)) continue;
      final token = CancelToken();
      _cancel = token;
      _inFlight = song.id;
      try {
        await fetcher.fetch(
          _client!.downloadUri(song.id),
          cache.baseFor(song.id),
          cancel: token,
        );
        if (_disposed || token.isCancelled) continue;
        await cache.evict(protect: _protected);
        _retryAfter.remove(song.id);
        if (cache.isCached(song.id)) await onCached?.call(song);
      } on Object {
        if (!token.isCancelled)
          _retryAfter[song.id] = DateTime.now().add(retryDelay);
        // A failed warm-up must never interrupt playback. A later plan retries it.
      } finally {
        _cancel = null;
        _inFlight = null;
      }
    }
  }

  void stop() {
    _pending = [];
    _wanted = {};
    _cancel?.cancel();
    _client = null;
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
