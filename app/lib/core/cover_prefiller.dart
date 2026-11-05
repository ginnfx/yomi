import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cover_crop.dart';
import 'cover_downloader.dart';
import 'cover_sizes.dart';
import 'models.dart';

/// Pause between covers, so the server stays free for music.
const Duration _defaultGap = Duration(milliseconds: 200);

/// How often to look again while covers on screen are downloading.
const Duration _defaultBusyCheck = Duration(seconds: 1);

/// How soon to carry on after a dropped connection, when nothing else wakes it first.
const Duration _defaultRetryAfter = Duration(minutes: 1);

/// Downloads every song's small cover ahead of time, one at a time, so lists show covers
/// straight away and offline.
///
/// Anything already saved is skipped, so this only does real work once, plus new songs.
/// It stops whenever [_canRun] says so, and [wake] carries on from where it left off.
class CoverPrefiller {
  CoverPrefiller({
    required CoverSource source,
    required List<Song> Function() songs,
    required bool Function() canRun,
    required String? Function(String coverId) urlFor,
    Duration gap = _defaultGap,
    Duration busyCheck = _defaultBusyCheck,
    Duration retryAfter = _defaultRetryAfter,
  }) : _source = source,
       _songs = songs,
       _canRun = canRun,
       _urlFor = urlFor,
       _gap = gap,
       _busyCheck = busyCheck,
       _retryAfter = retryAfter;

  final CoverSource _source;
  final List<Song> Function() _songs;
  final bool Function() _canRun;
  final String? Function(String coverId) _urlFor;
  final Duration _gap;
  final Duration _busyCheck;
  final Duration _retryAfter;
  Timer? _retry;

  /// Covers the server said it doesn't have, not asked for again until the next launch.
  final Set<String> _unavailable = {};
  List<Song>? _finishedFor;
  bool _isRunning = false;

  /// Starts or resumes, if there's anything to do and it's allowed. Safe to call often.
  Future<void> wake() async {
    if (_isRunning) return;
    final songs = _songs();
    if (identical(songs, _finishedFor) || !_canRun()) return;
    _isRunning = true;
    var isDone = false;
    try {
      isDone = await _fill(songs);
    } on Object catch (error) {
      debugPrint('Stopped saving covers ahead of time: $error');
    } finally {
      _isRunning = false;
    }
    if (isDone) {
      _finishedFor = songs;
    } else {
      _retry?.cancel();
      _retry = Timer(_retryAfter, () => unawaited(wake()));
    }
    if (!identical(_songs(), songs)) unawaited(wake());
  }

  /// Whether every cover in [songs] is now dealt with.
  Future<bool> _fill(List<Song> songs) async {
    final saved = await _source.savedKeys();
    for (final id in coversInOrder(songs)) {
      final key = coverCacheKey(id, smallCoverPx);
      if (saved.contains(key) || _unavailable.contains(key)) continue;
      if (await _source.saved(key) != null) continue;
      if (!await _waitForTurn(songs)) return false;
      final url = _urlFor(id);
      if (url == null) return false;
      try {
        await _source.download(url, key);
      } on CoverNotAvailable {
        _unavailable.add(key);
      } on Object catch (error) {
        // The connection dropped, so the rest would fail too. The next wake carries on.
        debugPrint('Paused saving covers ahead of time: $error');
        return false;
      }
      await Future<void>.delayed(_gap);
    }
    return true;
  }

  /// Gives way to covers on screen. False when this run should stop.
  Future<bool> _waitForTurn(List<Song> songs) async {
    while (true) {
      if (!_canRun() || !identical(_songs(), songs)) return false;
      if (!_source.isBusy) return true;
      await Future<void>.delayed(_busyCheck);
    }
  }
}

/// One cover ID per picture, newest songs first, as they're the likeliest to be looked at.
@visibleForTesting
List<String> coversInOrder(List<Song> songs) {
  final dated = [...songs]
    ..sort((a, b) {
      final first = a.addedAt;
      final second = b.addedAt;
      if (first == null || second == null) {
        return (first == null ? 1 : 0) - (second == null ? 1 : 0);
      }
      return second.compareTo(first);
    });
  final seen = <String>{};
  return [
    for (final song in dated)
      if (song.coverArtId case final id?)
        if (seen.add(coverCacheKey(id, smallCoverPx))) id,
  ];
}
