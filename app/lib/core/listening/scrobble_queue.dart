import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../subsonic_client.dart';

const int kMaxQueuedScrobbles = 2000;

@immutable
class PendingScrobble {
  const PendingScrobble(this.songId, this.playedAt);

  final String songId;
  final DateTime playedAt;

  Map<String, Object?> toJson() => {
    'id': songId,
    'at': playedAt.millisecondsSinceEpoch,
  };
}

/// Plays waiting to reach the server. Each keeps the time it really happened, so
/// listening offline still lands in the right place in history.
class ScrobbleQueue {
  ScrobbleQueue(this.file);

  final File file;
  List<PendingScrobble> _pending = const [];
  bool _isFlushing = false;

  List<PendingScrobble> get pending => _pending;

  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! List<dynamic>) return;
      _pending = List.unmodifiable(
        json.cast<Map<String, dynamic>>().map(
          (raw) => PendingScrobble(
            raw['id'] as String,
            DateTime.fromMillisecondsSinceEpoch((raw['at'] as num).toInt()),
          ),
        ),
      );
    } on Object catch (error) {
      debugPrint('Discarding unreadable scrobble queue: $error');
      _pending = const [];
    }
  }

  Future<void> add(PendingScrobble scrobble) async {
    final grown = [..._pending, scrobble];
    _pending = List.unmodifiable(
      grown.length > kMaxQueuedScrobbles
          ? grown.skip(grown.length - kMaxQueuedScrobbles)
          : grown,
    );
    await _save();
  }

  /// Sends everything it can, oldest first. Stops when the server can't be
  /// reached, and drops only plays the server itself refuses, such as a song
  /// that has since been deleted.
  Future<void> flush(SubsonicClient client) async {
    if (_isFlushing) return;
    _isFlushing = true;
    try {
      while (_pending.isNotEmpty) {
        final next = _pending.first;
        try {
          await client.scrobble(next.songId, time: next.playedAt);
        } on SubsonicException catch (error) {
          final isTemporary =
              error.kind == ErrorKind.unreachable ||
              error.kind == ErrorKind.server ||
              error.isBadCredentials;
          if (isTemporary) return;
          debugPrint('Server refused a queued play: $error');
        }
        _pending = List.unmodifiable(_pending.skip(1));
        await _save();
      }
    } finally {
      _isFlushing = false;
    }
  }

  Future<void> _save() async {
    final temp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temp.writeAsString(
        jsonEncode([for (final item in _pending) item.toJson()]),
      );
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save scrobble queue: $error');
    }
  }
}
