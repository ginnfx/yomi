import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../core/models.dart';
import '../core/offline/audio_cache.dart';
import '../core/offline/audio_preloader.dart';
import '../core/offline/file_fetcher.dart';
import '../core/subsonic_client.dart';
import 'connectivity_controller.dart';
import 'download_manager.dart';
import 'settings.dart';

/// Owns the audio player and the play queue; the UI listens to this.
class PlayerController extends ChangeNotifier {
  PlayerController(
    this._player, {
    required this.cache,
    required this.downloads,
    required this.settings,
    required this.connectivity,
    this.fetcher = const FileFetcher(),
  }) {
    _preloader = AudioPreloader(
      cache: cache,
      fetcher: fetcher,
      onCached: (song) async {
        await _switchQueuedToLocal(song);
        if (!_disposed) notifyListeners();
      },
    );
    settings.addListener(_onCacheSettingsChanged);
    connectivity.addListener(_onCacheSettingsChanged);
    _subscriptions
      ..add(_player.currentIndexStream.listen(_onIndexChanged))
      ..add(_player.bufferedPositionStream.listen(_onBuffered))
      ..add(_player.playerStateStream.listen((_) => notifyListeners()))
      ..add(_player.shuffleModeEnabledStream.listen((_) => notifyListeners()))
      ..add(_player.loopModeStream.listen((_) => notifyListeners()))
      ..add(
        _player.playbackEventStream.listen((_) {}, onError: _onPlaybackError),
      );
  }

  final AudioPlayer _player;
  final AudioCache cache;
  final DownloadManager downloads;
  final SettingsController settings;
  final ConnectivityController connectivity;
  final FileFetcher fetcher;
  bool _disposed = false;
  late final AudioPreloader _preloader;
  String? _retriedSongId;
  String? _warmCurrentId;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  SubsonicClient? _client;
  List<Song> _queue = const [];
  int? _index;
  String? _error;

  /// Called after sign-in/out so stream and cover URLs use the right credentials.
  void attach(SubsonicClient? client) {
    _client = client;
    if (client == null) {
      _preloader.stop();
      _player.stop();
      _queue = const [];
      _index = null;
      notifyListeners();
    }
  }

  List<Song> get queue => _queue;
  int? get index => _index;
  Song? get current =>
      (_index != null && _index! < _queue.length) ? _queue[_index!] : null;
  bool get isPlaying => _player.playing;
  bool get isBuffering =>
      _player.processingState == ProcessingState.loading ||
      _player.processingState == ProcessingState.buffering;
  bool get isShuffled => _player.shuffleModeEnabled;
  LoopMode get loopMode => _player.loopMode;
  String? get error => _error;
  bool get isCurrentCached => current != null && _isLocal(current!);
  double get volume => _player.volume;
  Future<void> setVolume(double value) => _player.setVolume(value);
  Duration get position => _player.position;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration> get bufferedStream => _player.bufferedPositionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  /// Order of preference: a saved download, an already-cached copy, then a direct stream.
  /// Saved files keep their real extension (iOS cannot open anything else).
  AudioSource _sourceFor(Song song, {bool allowLocal = true}) {
    final client = _client!;
    final tag = MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration,
      artUri: song.coverArtId == null
          ? null
          : client.coverArtUri(song.coverArtId, size: 600),
    );
    if (allowLocal) {
      final local = downloads.localFile(song.id) ?? cache.find(song.id);
      if (local != null) return AudioSource.file(local.path, tag: tag);
    }
    return AudioSource.uri(client.streamUri(song.id), tag: tag);
  }

  bool _isLocal(Song song) =>
      downloads.isDownloaded(song.id) || cache.isCached(song.id);

  /// Start warming once playback has a safe head start, rather than waiting
  /// for AVPlayer to buffer an entire (possibly very long) song.
  void _onBuffered(Duration buffered) {
    final song = current;
    if (song == null) return;
    final total = _player.duration ?? song.duration;
    final hasHeadroom =
        buffered - _player.position >= const Duration(seconds: 10);
    final fullyBuffered =
        total > Duration.zero && buffered + const Duration(seconds: 2) >= total;
    if (_isLocal(song) || hasHeadroom || fullyBuffered) {
      _scheduleCaching(
        includeCurrent: settings.cachePlayedSongs && connectivity.isOnWifi,
      );
    }
  }

  void _onCacheSettingsChanged() {
    cache.maxBytes = settings.cacheLimitBytes;
    if (connectivity.isOffline ||
        (!settings.preloadNext && !settings.cachePlayedSongs)) {
      _preloader.stop();
      return;
    }
    _onBuffered(_player.bufferedPosition);
  }

  void _scheduleCaching({required bool includeCurrent}) {
    final index = _index;
    final client = _client;
    if (client == null || index == null || connectivity.isOffline) return;
    final order = _player.effectiveIndices;
    final position = order.indexOf(index);
    if (position < 0) return;
    final count = settings.preloadNext ? (connectivity.isOnWifi ? 3 : 1) : 0;
    final indexes = [
      if (includeCurrent) index,
      ...order.skip(position + 1).take(count),
    ];
    _preloader.plan(
      client,
      [
        for (final i in indexes)
          if (i < _queue.length && !downloads.isDownloaded(_queue[i].id))
            _queue[i],
      ],
      protect: {if (current != null) current!.id},
    );
  }

  Future<void> _switchQueuedToLocal(Song song) async {
    for (var i = 0; i < _queue.length; i++) {
      // The playing item is never touched; only songs still waiting in the queue are swapped.
      if (_queue[i].id != song.id ||
          i <= (_index ?? -1) ||
          _player.audioSources.length != _queue.length)
        continue;
      try {
        await _player.removeAudioSourceAt(i);
        await _player.insertAudioSource(i, _sourceFor(song));
      } on Object catch (error) {
        debugPrint('Could not switch ${song.title} to its cached copy: $error');
      }
    }
  }

  /// If the playing source fails, retry once over the network (dropping a bad saved copy).
  Future<bool> _retryOverNetwork() async {
    final song = current;
    final index = _index;
    if (song == null ||
        index == null ||
        _client == null ||
        _retriedSongId == song.id)
      return false;
    _retriedSongId = song.id;
    final position = _player.position;
    try {
      await cache.remove(song.id);
      await _player.removeAudioSourceAt(index);
      await _player.insertAudioSource(
        index,
        _sourceFor(song, allowLocal: false),
      );
      await _player.seek(position, index: index);
      unawaited(_player.play());
      return true;
    } on Object catch (error) {
      debugPrint('Retry over the network failed: $error');
      return false;
    }
  }

  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    if (_client == null || songs.isEmpty) return;
    _preloader.stop();
    _error = null;
    _queue = List.unmodifiable(songs);
    _index = startIndex.clamp(0, songs.length - 1);
    notifyListeners();
    try {
      await _player.setAudioSources(
        songs.map(_sourceFor).toList(),
        initialIndex: _index,
        initialPosition: position,
      );
      if (autoplay) {
        unawaited(_player.play());
      } else if (defaultTargetPlatform == TargetPlatform.macOS &&
          connectivity.isOnWifi) {
        // Prepare a handoff in the background while the phone keeps playing.
        _scheduleCaching(
          includeCurrent: settings.cachePlayedSongs && connectivity.isOnWifi,
        );
      }
    } on Object catch (error) {
      _fail(error);
    }
  }

  Future<void> addToQueue(Song song) async {
    if (_queue.isEmpty) return playQueue([song]);
    _queue = List.unmodifiable([..._queue, song]);
    notifyListeners();
    await _player.addAudioSource(_sourceFor(song));
  }

  Future<void> playNext(Song song) async {
    if (_queue.isEmpty) return playQueue([song]);
    final at = (_index ?? -1) + 1;
    _queue = List.unmodifiable([..._queue.take(at), song, ..._queue.skip(at)]);
    notifyListeners();
    await _player.insertAudioSource(at, _sourceFor(song));
  }

  Future<void> jumpTo(int queueIndex) async {
    await _player.seek(Duration.zero, index: queueIndex);
    unawaited(_player.play());
  }

  Future<void> togglePlay() =>
      _player.playing ? _player.pause() : _player.play();
  Future<void> next() => _player.seekToNext();
  Future<void> previous() async {
    if (_player.position > const Duration(seconds: 3))
      return _player.seek(Duration.zero);
    return _player.seekToPrevious();
  }

  Future<void> pause() => _player.pause();

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    notifyListeners();
  }

  Future<void> toggleShuffle() =>
      _player.setShuffleModeEnabled(!_player.shuffleModeEnabled);

  Future<void> cycleRepeat() {
    const order = [LoopMode.off, LoopMode.all, LoopMode.one];
    return _player.setLoopMode(
      order[(order.indexOf(_player.loopMode) + 1) % order.length],
    );
  }

  void _onIndexChanged(int? index) {
    _index = index;
    final song = current;
    if (song?.id != _warmCurrentId) {
      _preloader.stop();
      _warmCurrentId = song?.id;
    }
    if (song != null) unawaited(cache.touch(song.id));
    _retriedSongId = song?.id == _retriedSongId ? _retriedSongId : null;
    if (song != null && _isLocal(song)) _scheduleCaching(includeCurrent: false);
    notifyListeners();
  }

  void _onPlaybackError(Object error) async {
    if (await _retryOverNetwork()) return;
    _fail(error);
  }

  void _fail(Object error) {
    _error = connectivity.isOffline
        ? "You're offline. Download songs to play them without a connection."
        : 'Playback problem. Check your connection to the server.';
    debugPrint('Playback error: $error');
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_onCacheSettingsChanged);
    connectivity.removeListener(_onCacheSettingsChanged);
    _preloader.dispose();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
