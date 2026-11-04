import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/saved_play_queue.dart';
import '../core/subsonic_client.dart';
import 'player_controller.dart';
import 'settings.dart';

/// Navidrome holds one queue per account. Only the device the user starts
/// listening on publishes updates; other devices follow it without autoplay.
class PlaybackSyncController extends ChangeNotifier
    with WidgetsBindingObserver {
  PlaybackSyncController({
    required this.player,
    required this.settings,
    required this.deviceId,
    this.pollInterval = const Duration(seconds: 5),
    this.saveInterval = const Duration(seconds: 5),
  }) {
    player.addListener(_onPlayer);
    settings.addListener(_onSettings);
    WidgetsBinding.instance.addObserver(this);
    _rememberPlayer();
  }

  final PlayerController player;
  final SettingsController settings;
  final String deviceId;
  final Duration pollInterval;
  final Duration saveInterval;
  SubsonicClient? _client;
  Timer? _poll;
  Timer? _debounce;
  Future<void>? _active;
  SavedPlayQueue? _remote;
  String? _remoteRevision;
  String? _error;
  DateTime? _lastSaved;
  bool _ownsPlayback = false;
  bool _claim = false;
  bool _applying = false;
  bool _takingOver = false;
  bool _disposed = false;
  int _epoch = 0;
  List<Object?> _observed = const [];

  SavedPlayQueue? get remote => _remote;
  String? get error => _error;
  DateTime? get lastSaved => _lastSaved;
  bool get isTakingOver => _takingOver;
  bool get isBusy => _active != null || _takingOver;
  bool get enabled => settings.syncListening;

  void attach(SubsonicClient? client) {
    if (_client != null &&
        client != null &&
        _client!.username == client.username) {
      _client = client; // Home/away failover is still the same account.
      return;
    }
    _epoch++;
    _client = client;
    _poll?.cancel();
    _debounce?.cancel();
    _remote = null;
    _remoteRevision = null;
    _error = null;
    _lastSaved = null;
    _ownsPlayback = false;
    _claim = false;
    _rememberPlayer();
    _startPolling();
    notifyListeners();
  }

  void _startPolling() {
    _poll?.cancel();
    if (_client == null || !enabled) return;
    _poll = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  void _onSettings() {
    if (!enabled) {
      _poll?.cancel();
      _debounce?.cancel();
      _ownsPlayback = false;
      _claim = false;
      _remote = null;
    } else if (!(_poll?.isActive ?? false)) {
      _startPolling();
    }
    notifyListeners();
  }

  List<Object?> _snapshot() => [player.queue, player.index, player.isPlaying];
  void _rememberPlayer() => _observed = _snapshot();

  void _onPlayer() {
    final now = _snapshot();
    final queueChanged = !identical(now[0], _observed.firstOrNull);
    final started =
        now[2] == true && (_observed.length < 3 || _observed[2] != true);
    _observed = now;
    if (_applying || !enabled || _client == null || player.current == null) {
      return;
    }
    if (queueChanged || started) {
      _ownsPlayback = true;
      _claim = true;
      _remote = null;
      notifyListeners();
    }
    if (_ownsPlayback) {
      _debounce?.cancel();
      _debounce = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(saveNow()),
      );
    }
  }

  Future<void> _run(Future<void> Function(int epoch) action) {
    if (_active != null) return _active!;
    final epoch = _epoch;
    final operation = () async {
      try {
        await action(epoch);
        if (epoch == _epoch && !_disposed) _error = null;
      } on Object {
        if (epoch == _epoch && !_disposed) {
          _error = 'Listening sync is waiting for your server.';
        }
      }
    }();
    _active = operation.whenComplete(() {
      _active = null;
      if (!_disposed) notifyListeners();
    });
    return _active!;
  }

  bool _valid(int epoch) =>
      !_disposed && epoch == _epoch && enabled && _client != null;

  /// Read before publishing, so an old paused device cannot overwrite a handoff.
  Future<void> refresh() {
    if (_client == null || !enabled || _disposed || _applying) {
      return Future.value();
    }
    return _run((epoch) async {
      final remote = await _client!.savedPlayQueue();
      if (!_valid(epoch)) return;
      await _acceptRemote(remote, epoch);
      if (!_valid(epoch)) return;
      if (_ownsPlayback &&
          player.isPlaying &&
          (_lastSaved == null ||
              DateTime.now().difference(_lastSaved!) >= saveInterval)) {
        await _publish(epoch);
      }
    });
  }

  bool _hasQueue(SavedPlayQueue remote) =>
      player.index == remote.index &&
      player.queue.length == remote.songs.length &&
      List.generate(
        remote.songs.length,
        (i) => player.queue[i].id == remote.songs[i].id,
      ).every((same) => same);

  Future<void> _restore(SavedPlayQueue remote) async {
    if (_hasQueue(remote) && player.error == null) {
      if ((player.position - remote.position).abs() >
          const Duration(seconds: 1)) {
        await player.seek(remote.position);
      }
    } else {
      await player.playQueue(
        remote.songs,
        startIndex: remote.index,
        position: remote.position,
        autoplay: false,
      );
    }
  }

  Future<void> _acceptRemote(SavedPlayQueue? remote, int epoch) async {
    if (remote == null || remote.revision == _remoteRevision) return;
    _remoteRevision = remote.revision;
    if (_claim || (remote.changedBy == deviceId && player.current != null)) {
      return;
    }
    _ownsPlayback = false;
    _debounce?.cancel();
    _remote = remote;
    _applying = true;
    try {
      // Stop the previous device when another client claims the account queue.
      // Restoring paused makes the next Play start at the shared position.
      await player.pause();
      if (!_valid(epoch)) return;
      await _restore(remote);
    } finally {
      _rememberPlayer();
      _applying = false;
    }
  }

  Future<void> saveNow() async {
    if (_active != null) await _active;
    if (_client == null ||
        !enabled ||
        _disposed ||
        !_ownsPlayback ||
        _applying) {
      return;
    }
    await _run((epoch) async {
      if (!_claim) {
        final remote = await _client!.savedPlayQueue();
        if (!_valid(epoch)) return;
        await _acceptRemote(remote, epoch);
      }
      if (_valid(epoch) && _ownsPlayback) await _publish(epoch);
    });
  }

  Future<void> _publish(int epoch) async {
    if (player.current == null || player.isBuffering) return;
    final queue = player.queue;
    final index = player.index;
    if (index == null || index < 0 || index >= queue.length) return;
    await _client!.savePlayQueue(
      songs: queue,
      index: index,
      position: player.position,
      deviceId: deviceId,
    );
    if (!_valid(epoch)) return;
    _claim = false;
    _lastSaved = DateTime.now();
  }

  /// Explicitly request a fresh queue before taking playback to this device.
  Future<void> continueHere() async {
    if (_takingOver || _disposed) return;
    _takingOver = true;
    notifyListeners();
    try {
      await _continueHere();
    } finally {
      _takingOver = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _continueHere() async {
    if (_active != null) await _active;
    await refresh();
    if (_client == null || !enabled || _disposed) return;
    final remote = _remote;
    if (remote == null && player.current == null) return;
    _applying = true;
    try {
      if (remote != null) {
        await _restore(remote);
      }
    } finally {
      _rememberPlayer();
      _applying = false;
    }
    _ownsPlayback = true;
    _claim = true;
    _remote = null;
    if (!player.isPlaying) unawaited(player.togglePlay());
    await saveNow();
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(saveNow());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _poll?.cancel();
    _debounce?.cancel();
    player.removeListener(_onPlayer);
    settings.removeListener(_onSettings);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
