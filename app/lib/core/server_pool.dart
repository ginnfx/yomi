/// Tracks which of Yomi's servers are healthy and how busy and fast each one is, so work
/// can be spread across all of them instead of always using one.
library;

const Duration kServerCooldown = Duration(seconds: 30);

/// Weight of the newest latency sample in the moving average.
const double _latencyWeight = 0.3;

/// Extra cost, per transfer already running on a server, as a share of its latency.
const double _busyPenalty = 1.0;

/// Latency assumed for a server that hasn't answered yet.
const Duration _untriedLatency = Duration(milliseconds: 250);

class ServerStats {
  const ServerStats({this.latency, this.inFlight = 0, this.failedAt});

  final Duration? latency;
  final int inFlight;
  final DateTime? failedAt;

  ServerStats copyWith({
    Duration? latency,
    int? inFlight,
    DateTime? failedAt,
    bool clearFailure = false,
  }) => ServerStats(
    latency: latency ?? this.latency,
    inFlight: inFlight ?? this.inFlight,
    failedAt: clearFailure ? null : (failedAt ?? this.failedAt),
  );
}

class ServerPool {
  ServerPool({this.cooldown = kServerCooldown, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Duration cooldown;
  final DateTime Function() _now;

  List<String> _servers = const [];
  Map<String, ServerStats> _stats = const {};
  Map<String, String> _routes = const {};

  List<String> get servers => List.unmodifiable(_servers);

  /// Replaces the server list. Servers that stay keep what has been learned about them.
  void setServers(List<String> urls) {
    final cleaned = {for (final u in urls) _clean(u)}.toList(growable: false);
    _servers = cleaned;
    _stats = {
      for (final url in cleaned) url: _stats[url] ?? const ServerStats(),
    };
  }

  /// The address to actually connect to for [url]: a local forwarding address when the
  /// server is reached through the embedded tunnel, otherwise [url] itself.
  String resolve(String url) => _routes[_clean(url)] ?? _clean(url);

  /// Records how [url] is reached right now. Null means directly.
  void setRoute(String url, String? local) {
    final key = _clean(url);
    final next = {..._routes}..remove(key);
    if (local != null) next[key] = _clean(local);
    _routes = next;
  }

  /// Servers to try, best first: not recently failed, then least busy and fastest.
  /// If every server has failed recently they are all returned, so work is never refused.
  List<String> rank() {
    final now = _now();
    final healthy = _servers.where((u) => !_isCoolingDown(u, now)).toList();
    final pool = healthy.isEmpty ? [..._servers] : healthy;
    final order = {for (var i = 0; i < _servers.length; i++) _servers[i]: i};
    pool.sort((x, y) {
      final byScore = _score(x).compareTo(_score(y));
      return byScore != 0 ? byScore : order[x]!.compareTo(order[y]!);
    });
    return List.unmodifiable(pool);
  }

  /// Marks a transfer as running on [url]. Call the returned function when it ends.
  void Function() lease(String url) {
    final key = _clean(url);
    _update(key, (s) => s.copyWith(inFlight: s.inFlight + 1));
    var isReleased = false;
    return () {
      if (isReleased) return;
      isReleased = true;
      _update(
        key,
        (s) => s.copyWith(inFlight: s.inFlight > 0 ? s.inFlight - 1 : 0),
      );
    };
  }

  void recordSuccess(String url, Duration latency) {
    _update(_clean(url), (s) {
      final previous = s.latency;
      final blended = previous == null
          ? latency
          : Duration(
              microseconds:
                  (previous.inMicroseconds * (1 - _latencyWeight) +
                          latency.inMicroseconds * _latencyWeight)
                      .round(),
            );
      return s.copyWith(latency: blended, clearFailure: true);
    });
  }

  void recordFailure(String url) {
    _update(_clean(url), (s) => s.copyWith(failedAt: _now()));
  }

  bool _isCoolingDown(String url, DateTime now) {
    final failedAt = _stats[url]?.failedAt;
    return failedAt != null && now.difference(failedAt) < cooldown;
  }

  double _score(String url) {
    final stats = _stats[url] ?? const ServerStats();
    final latency = (stats.latency ?? _untriedLatency).inMicroseconds;
    return latency * (1 + _busyPenalty * stats.inFlight);
  }

  void _update(String key, ServerStats Function(ServerStats) change) {
    if (!_stats.containsKey(key)) return;
    _stats = {..._stats, key: change(_stats[key]!)};
  }

  static String _clean(String url) => url.replaceAll(RegExp(r'/+$'), '');
}

/// Points a media address built for one server at [serverBase] instead, keeping the
/// `/rest/...` path and the whole query (the sign-in parameters work on every replica).
Uri rebaseOnServer(Uri original, String serverBase) {
  final index = original.path.indexOf('/rest/');
  if (index < 0) return original;
  final base = Uri.parse(serverBase.replaceAll(RegExp(r'/+$'), ''));
  return original.replace(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '${base.path}${original.path.substring(index)}',
  );
}
