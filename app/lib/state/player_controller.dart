import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../core/audio/yomi_audio_handler.dart';
import '../core/models.dart';
import '../core/offline/audio_cache.dart';
import '../core/offline/audio_files.dart';
import '../core/offline/audio_preloader.dart';
import '../core/offline/file_fetcher.dart';
import '../core/stall_detector.dart';
import '../core/subsonic_client.dart';
import 'connectivity_controller.dart';
import 'download_manager.dart';
import 'settings.dart';

const Duration _stallCheckEvery = Duration(seconds: 1);
const int _maxRecoveries = 3;

/// Owns the audio player and the play queue; the UI listens to this.
class PlayerController extends ChangeNotifier implements TransportCommands {
  PlayerController(
    this._player, {
    required this.cache,
    required this.downloads,
    required this.settings,
    required this.connectivity,
    this.fetcher = const FileFetcher(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _stallTimer = Timer.periodic(_stallCheckEvery, (_) => checkForStall());
    _preloader = AudioPreloader(
      cache: cache,
      fetcher: fetcher,
      onCached: (song) async {
        await _switchQueuedToLocal(song);
        if (!_disposed) notifyListeners();
      },
    );
    downloads.addListener(_onDownloadsChanged);
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

  /// Called when audio stops arriving, so the session can look for another server.
  void Function()? onStalled;

  final DateTime Function() _now;
  final StallDetector _stalls = StallDetector();
  late final Timer _stallTimer;
  bool _needsNewSources = false;

  /// Told about the next song in the queue, so its extras can be ready in time.
  void Function(SubsonicClient client, Song song)? onUpcomingSong;
  bool _disposed = false;
  late final AudioPreloader _preloader;
  String? _retriedSongId;
  String? _recoveringSongId;
  int _recoveries = 0;
  String? _warmCurrentId;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  SubsonicClient? _client;
  List<Song> _queue = const [];
  int? _index;
  String? _error;

  /// Where a skip is heading, until the player catches up. While set, reports from the
  /// player about the old song are ignored.
  int? _pendingIndex;

  /// Rises with every load. A load that's been replaced stays quiet when it finishes.
  int _loadGeneration = 0;

  /// Set from the moment playback is asked for until the player has really started, so a
  /// skip tapped in between doesn't forget it.
  bool _shouldPlayAfterLoad = false;
  _HeldShuffleOrder? _heldOrder;
  int _userSkips = 0;

  /// Songs to continue with when the queue runs out. Set by whoever knows what to suggest.
  List<Song> Function()? suggestNext;

  /// Set while the server can't be reached even though there's a network.
  bool isServerDown = false;

  bool get _isDisconnected => connectivity.isOffline || isServerDown;

  /// Whether this song can play right now. While disconnected only saved songs can.
  bool isAvailableNow(Song song) => !_isDisconnected || _isLocal(song);

  /// Rises each time the user skips, including from the lock screen.
  int get userSkips => _userSkips;

  /// Whether Next would do anything right now.
  bool get canSkipNext =>
      _targetFrom(1) != null || _newSuggestions().isNotEmpty;

  /// Called after sign-in/out so stream and cover URLs use the right credentials.
  void attach(SubsonicClient? client) {
    final previous = _client;
    _client = client;
    if (client == null) {
      _preloader.stop();
      _player.stop();
      _queue = const [];
      _index = null;
      _needsNewSources = false;
      notifyListeners();
      return;
    }
    final hasMoved = previous != null && previous.baseUrl != client.baseUrl;
    if (!hasMoved || _queue.isEmpty) return;
    // Queued songs still point at the old address. If music is flowing, the switch waits
    // for the next song so nothing is heard; if not, it happens now.
    if (_isFlowing) {
      _needsNewSources = true;
    } else {
      unawaited(_reloadSources());
    }
  }

  /// Starts the current song again after the server came back at the same address.
  /// A failed song is only given [_maxRecoveries] of these, so one that can't play at
  /// all doesn't reload forever.
  void resumeAfterFailure() {
    final song = current;
    final hasFailed = _error != null || _stalls.isStalled;
    if (_disposed || song == null || !hasFailed || _isDisconnected) return;
    if (_recoveringSongId != song.id) {
      _recoveringSongId = song.id;
      _recoveries = 0;
    }
    if (_recoveries >= _maxRecoveries) return;
    _recoveries++;
    unawaited(_reloadSources());
  }

  bool get _isFlowing =>
      _player.playing &&
      _player.processingState == ProcessingState.ready &&
      !_stalls.isStalled &&
      _error == null;

  /// Reloads the queue from the current address, keeping the song and position.
  Future<void> _reloadSources({bool fromStart = false}) async {
    final index = _index;
    if (_client == null || index == null || _queue.isEmpty) return;
    _needsNewSources = false;
    final wasPlaying = _player.playing;
    final position = fromStart ? Duration.zero : _player.position;
    _error = null;
    _stalls.reset();
    _shouldPlayAfterLoad = _shouldPlayAfterLoad || wasPlaying;
    final order = _player.shuffleModeEnabled
        ? (_heldOrder ??= _HeldShuffleOrder(_order))
        : null;
    await _load(index, position, shuffleOrder: order);
    if (!_disposed) notifyListeners();
  }

  /// Loads the whole queue at [index]. A newer load takes over from an older one, so the
  /// latest tap always wins; only the newest load reports a failure or starts playback.
  Future<void> _load(
    int index,
    Duration position, {
    ShuffleOrder? shuffleOrder,
  }) async {
    final generation = ++_loadGeneration;
    try {
      await _player.setAudioSources(
        _sourcesForQueue(),
        initialIndex: index,
        initialPosition: position,
        shuffleOrder: shuffleOrder,
      );
      if (generation != _loadGeneration) return;
      _heldOrder?.release();
      _heldOrder = null;
      _pendingIndex = null;
      if (_shouldPlayAfterLoad) {
        _shouldPlayAfterLoad = false;
        unawaited(_player.play());
      }
    } on PlayerInterruptedException {
      // Something newer replaced this load, which is exactly what should happen.
    } on Object catch (error) {
      if (generation != _loadGeneration) return;
      _pendingIndex = null;
      _shouldPlayAfterLoad = false;
      _fail(error);
    }
  }

  /// Lists the cache folder once rather than checking disk for each song, which froze
  /// the screen on long queues.
  List<AudioSource> _sourcesForQueue() {
    final cached = cache.savedFiles();
    return [for (final song in _queue) _sourceFor(song, cached: cached)];
  }

  /// The order songs play in, for showing the queue as it will really play.
  List<int> get playOrder => _order;

  /// The order songs play in. During a load the player's own answer may be out of date,
  /// so the one the load started from is used.
  List<int> get _order {
    final held = _heldOrder;
    if (held != null) return held.indices;
    final order = _player.effectiveIndices;
    return order.length == _queue.length
        ? order
        : [for (var i = 0; i < _queue.length; i++) i];
  }

  /// The queue position [step] songs along, or null at the end of a queue that doesn't
  /// repeat. Repeat-one doesn't count here: skipping means you want a different song.
  int? _targetFrom(int step) {
    final index = _index;
    if (index == null || _queue.isEmpty) return null;
    final order = _order;
    final position = order.indexOf(index);
    if (position < 0) return null;
    final target = position + step;
    if (target >= 0 && target < order.length) return order[target];
    return _player.loopMode == LoopMode.all
        ? order[target % order.length]
        : null;
  }

  List<Song> _newSuggestions() {
    final suggest = suggestNext;
    if (suggest == null || _queue.isEmpty) return const [];
    final queued = {for (final song in _queue) song.id};
    return [
      for (final song in suggest())
        if (!queued.contains(song.id)) song,
    ];
  }

  Future<void> _skipTo(int target) async {
    _userSkips++;
    _index = target;
    _pendingIndex = target;
    _error = null;
    debugPrint(
      'Skip to $target of ${_queue.length}: ${_player.processingState.name}, '
      'playing ${_player.playing}, repeat ${_player.loopMode.name}, '
      'shuffle ${_player.shuffleModeEnabled}',
    );
    notifyListeners();
    final state = _player.processingState;
    final mustReload =
        state == ProcessingState.loading ||
        state == ProcessingState.idle ||
        _needsNewSources ||
        _hasStaleLocalSource(target);
    if (!mustReload) {
      await _player.seek(Duration.zero, index: target);
      if (_pendingIndex == target) _pendingIndex = null;
      return;
    }
    // The player ignores seeks while loading, but a new load replaces the current one.
    _needsNewSources = false;
    _shouldPlayAfterLoad = _shouldPlayAfterLoad || _player.playing;
    ShuffleOrder? shuffleOrder;
    if (_player.shuffleModeEnabled) {
      shuffleOrder = _heldOrder ??= _HeldShuffleOrder(_order);
    }
    await _load(target, Duration.zero, shuffleOrder: shuffleOrder);
    if (!_disposed) notifyListeners();
  }

  /// Runs on a timer. Public so tests can drive it.
  void checkForStall() {
    final didStall = _stalls.update(
      isPlaying: _player.playing,
      position: _player.position,
      now: _now(),
    );
    if (!didStall) return;
    debugPrint('Playback stalled');
    if (_needsNewSources) unawaited(_reloadSources());
    onStalled?.call();
  }

  List<Song> get queue => _queue;
  int? get index => _index;
  Song? get current =>
      (_index != null && _index! < _queue.length) ? _queue[_index!] : null;
  @override
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
  AudioSource _sourceFor(
    Song song, {
    bool allowLocal = true,
    Map<String, File>? cached,
  }) {
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
    // Songs from YouTube exist only as a file on this device.
    final external = _externalFiles[song.id];
    if (external != null) return AudioSource.file(external.path, tag: tag);
    if (allowLocal) {
      final local =
          downloads.localFile(song.id) ??
          (cached == null ? cache.find(song.id) : cached[safeFileId(song.id)]);
      if (local != null) return AudioSource.file(local.path, tag: tag);
    }
    return AudioSource.uri(client.streamUri(song.id), tag: tag);
  }

  bool _isLocal(Song song) =>
      _externalFiles.containsKey(song.id) ||
      downloads.isDownloaded(song.id) ||
      cache.isCached(song.id);

  final Map<String, File> _externalFiles = {};

  /// Lets [song] play from [file] although the server doesn't have it.
  void registerExternalFile(Song song, File file) =>
      _externalFiles[song.id] = file;

  File? externalFileFor(Song song) => _externalFiles[song.id];

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
      _scheduleCaching(includeCurrent: connectivity.isOnWifi);
    }
  }

  void _onCacheSettingsChanged() {
    if (connectivity.isOffline) {
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
    final count = connectivity.isOnWifi ? 3 : 1;
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

  bool _hasStaleLocalSource(int index) {
    if (index < 0 || index >= _queue.length || !_isLocal(_queue[index])) {
      return false;
    }
    final sources = _player.audioSources;
    if (sources.length != _queue.length) return false;
    final source = sources[index];
    return source is UriAudioSource && source.uri.scheme != 'file';
  }

  void _onDownloadsChanged() {
    if (_disposed || _needsNewSources) return;
    for (var i = 0; i < _queue.length; i++) {
      if (downloads.isDownloaded(_queue[i].id) && _hasStaleLocalSource(i)) {
        _needsNewSources = true;
        notifyListeners();
        return;
      }
    }
  }

  Future<void> _switchQueuedToLocal(Song song) async {
    if (_disposed) return;
    // Rebuild on advancement instead of inserting/removing native sources while
    // another queue edit may be in flight. The current song keeps playing untouched.
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == song.id && _hasStaleLocalSource(i)) {
        _needsNewSources = true;
        return;
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
    if (_isDisconnected) {
      // Only what's saved can play, starting from the tapped song if it's one of them.
      final tapped = songs[startIndex.clamp(0, songs.length - 1)];
      final saved = songs.where(_isLocal).toList();
      if (saved.isEmpty) {
        _fail('Nothing here is saved on this device');
        return;
      }
      songs = saved;
      startIndex = max(saved.indexOf(tapped), 0);
      if (!identical(saved.first, tapped) && !saved.contains(tapped)) {
        position = Duration.zero;
      }
    }
    _preloader.stop();
    _error = null;
    _queue = List.unmodifiable(songs);
    final index = startIndex.clamp(0, songs.length - 1);
    _index = index;
    _pendingIndex = null;
    _heldOrder = null;
    _shouldPlayAfterLoad = autoplay;
    notifyListeners();
    final generation = _loadGeneration + 1;
    await _load(index, position);
    if (!autoplay &&
        generation == _loadGeneration &&
        _error == null &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux) &&
        connectivity.isOnWifi) {
      // Prepare a handoff in the background while the phone keeps playing.
      _scheduleCaching(includeCurrent: connectivity.isOnWifi);
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
    _shouldPlayAfterLoad = true;
    await _skipTo(queueIndex);
    if (_pendingIndex == null &&
        _player.processingState != ProcessingState.idle) {
      _shouldPlayAfterLoad = false;
      unawaited(_player.play());
    }
  }

  @override
  Future<void> togglePlay() =>
      _player.playing ? _player.pause() : _player.play();
  @override
  Future<void> next() async {
    final target = _targetFrom(1);
    if (target != null) return _skipTo(target);
    final more = _newSuggestions();
    if (more.isEmpty) return;
    final first = _queue.length;
    _queue = List.unmodifiable([..._queue, ...more]);
    await _player.addAudioSources(more.map(_sourceFor).toList());
    return _skipTo(first);
  }

  @override
  Future<void> previous() async {
    if (_player.position > const Duration(seconds: 3)) {
      return _player.seek(Duration.zero);
    }
    final target = _targetFrom(-1);
    if (target != null) return _skipTo(target);
    return _player.seek(Duration.zero);
  }

  @override
  Future<void> pause() => _player.pause();

  @override
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
    final pending = _pendingIndex;
    if (pending != null && index != pending) return;
    _pendingIndex = null;
    final didChangeSong = index != _index;
    _index = index;
    if (didChangeSong &&
        index != null &&
        (_needsNewSources || _hasStaleLocalSource(index))) {
      unawaited(_reloadSources(fromStart: true));
    }
    final song = current;
    if (song?.id != _warmCurrentId) {
      _preloader.stop();
      _warmCurrentId = song?.id;
    }
    if (song != null) unawaited(cache.touch(song.id));
    _retriedSongId = song?.id == _retriedSongId ? _retriedSongId : null;
    if (song != null && _isLocal(song)) _scheduleCaching(includeCurrent: false);
    _announceUpcoming();
    notifyListeners();
  }

  void _announceUpcoming() {
    final index = _index;
    final client = _client;
    final notify = onUpcomingSong;
    if (index == null || client == null || notify == null) return;
    final order = _player.effectiveIndices;
    final position = order.indexOf(index);
    if (position < 0 || position + 1 >= order.length) return;
    final nextIndex = order[position + 1];
    if (nextIndex < _queue.length) notify(client, _queue[nextIndex]);
  }

  void _onPlaybackError(Object error) async {
    if (await _retryOverNetwork()) return;
    _fail(error);
    onStalled?.call();
  }

  void _fail(Object error) {
    _error = _isDisconnected
        ? "You're offline. Download songs to play them without a connection."
        : 'Playback problem. Check your connection to the server.';
    debugPrint('Playback error: $error');
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stallTimer.cancel();
    downloads.removeListener(_onDownloadsChanged);
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

/// A shuffled order that stays as it is while a reload is happening, then goes back to
/// shuffling normally. A plain reload would otherwise pick a new random order.
class _HeldShuffleOrder extends DefaultShuffleOrder {
  _HeldShuffleOrder(List<int> order) {
    indices.addAll(order);
  }

  bool _isHeld = true;

  void release() => _isHeld = false;

  @override
  void shuffle({int? initialIndex}) {
    if (!_isHeld) super.shuffle(initialIndex: initialIndex);
  }
}
