const Duration kStallAfter = Duration(seconds: 6);

/// Notices when playback should be moving but isn't. Reports once per stall, so one
/// dead server doesn't trigger a failover check every second.
class StallDetector {
  StallDetector({this.threshold = kStallAfter});

  final Duration threshold;
  Duration? _lastPosition;
  DateTime? _stuckSince;
  bool _hasReported = false;

  bool get isStalled => _hasReported;

  /// Returns true the moment a stall is first detected.
  bool update({
    required bool isPlaying,
    required Duration position,
    required DateTime now,
  }) {
    if (!isPlaying || position != _lastPosition) {
      _lastPosition = position;
      _stuckSince = null;
      _hasReported = false;
      return false;
    }
    final since = _stuckSince ??= now;
    if (_hasReported || now.difference(since) < threshold) return false;
    _hasReported = true;
    return true;
  }

  void reset() {
    _lastPosition = null;
    _stuckSince = null;
    _hasReported = false;
  }
}
