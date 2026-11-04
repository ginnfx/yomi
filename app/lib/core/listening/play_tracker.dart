import '../models.dart';

/// Share of a song that counts as having really listened to it.
const double kFullPlayShare = 0.8;

/// Last.fm's scrobble rule: half the song, or four minutes, whichever comes first.
const double kScrobbleShare = 0.5;
const Duration kScrobbleAfter = Duration(minutes: 4);

/// Leaving a song before this much listening counts as skipping it.
const Duration kSkipBefore = Duration(seconds: 30);

/// A larger jump between position ticks is a seek or a stall, not listening.
const Duration _maxTick = Duration(seconds: 3);
const Duration _restartWithin = Duration(seconds: 3);

/// Turns the player's position ticks into listening events, counting only time
/// actually heard so seeking to the end doesn't count as a play.
class PlayTracker {
  PlayTracker({
    required this.onStarted,
    required this.onScrobble,
    required this.onCompleted,
    required this.onSkipped,
  });

  final void Function(Song song) onStarted;

  /// [startedAt] is when listening began, which is the time a scrobble reports.
  final void Function(Song song, DateTime startedAt) onScrobble;
  final void Function(Song song, DateTime at) onCompleted;
  final void Function(Song song, DateTime at) onSkipped;

  Song? _song;
  DateTime? _startedAt;
  Duration _listened = Duration.zero;
  Duration _lastPosition = Duration.zero;
  bool _hasScrobbled = false;
  bool _hasCompleted = false;

  void trackChanged(Song? song, DateTime now) {
    if (song?.id == _song?.id) return;
    _finish(now);
    _begin(song, now);
  }

  void position(
    Duration position, {
    required bool isPlaying,
    required DateTime now,
  }) {
    final song = _song;
    if (song == null) return;
    final didRestart =
        _hasCompleted &&
        position < _restartWithin &&
        _lastPosition - position > _restartWithin;
    if (didRestart) {
      // Repeat-one replays without changing track, so each loop is its own play.
      _begin(song, now);
      _lastPosition = position;
      return;
    }
    final tick = position - _lastPosition;
    _lastPosition = position;
    if (isPlaying && tick > Duration.zero && tick <= _maxTick) {
      _listened += tick;
      _evaluate(song, now);
    }
  }

  void _begin(Song? song, DateTime now) {
    _song = song;
    _startedAt = now;
    _listened = Duration.zero;
    _lastPosition = Duration.zero;
    _hasScrobbled = false;
    _hasCompleted = false;
    if (song != null) onStarted(song);
  }

  void _evaluate(Song song, DateTime now) {
    final total = song.duration;
    if (!_hasScrobbled && _reachedScrobble(total)) {
      _hasScrobbled = true;
      onScrobble(song, _startedAt!);
    }
    if (!_hasCompleted &&
        total > Duration.zero &&
        _listened >= total * kFullPlayShare) {
      _hasCompleted = true;
      onCompleted(song, now);
    }
  }

  bool _reachedScrobble(Duration total) {
    if (_listened >= kScrobbleAfter) return true;
    return total > Duration.zero && _listened >= total * kScrobbleShare;
  }

  void _finish(DateTime now) {
    final song = _song;
    if (song == null || _hasScrobbled || _hasCompleted) return;
    if (_listened < kSkipBefore) onSkipped(song, now);
  }
}
