import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/server_status.dart';

const Duration kDashboardRefresh = Duration(seconds: 15);

enum ServerReachability { checking, online, offline, needsUpdate }

typedef StatusFetcher = Future<ServerStatus> Function();
typedef PingFetcher = Future<void> Function();

/// Refreshes server health while the dashboard is open, and only then.
class DashboardController extends ChangeNotifier {
  DashboardController({
    required this.fetchStatus,
    required this.ping,
    Duration refreshEvery = kDashboardRefresh,
  }) : _refreshEvery = refreshEvery;

  final StatusFetcher fetchStatus;
  final PingFetcher ping;
  final Duration _refreshEvery;
  Timer? _timer;
  bool _isDisposed = false;
  bool _isRefreshing = false;

  ServerReachability reachability = ServerReachability.checking;
  ServerStatus? status;
  Duration? deviceLatency;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_refreshEvery, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    try {
      final watch = Stopwatch()..start();
      try {
        await ping();
        deviceLatency = watch.elapsed;
      } on Object catch (error) {
        // The upload service can be up while Navidrome is down, so keep going.
        debugPrint('Dashboard ping failed: $error');
        deviceLatency = null;
      }
      try {
        status = await fetchStatus();
        reachability = ServerReachability.online;
      } on StatusRouteMissing {
        status = null;
        reachability = deviceLatency == null
            ? ServerReachability.offline
            : ServerReachability.needsUpdate;
      } on Object catch (error) {
        debugPrint('Dashboard status failed: $error');
        status = null;
        reachability = ServerReachability.offline;
      }
    } finally {
      _isRefreshing = false;
      if (!_isDisposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
