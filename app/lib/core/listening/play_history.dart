import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models.dart';

/// Old enough that it no longer says anything about current taste.
const Duration kHistoryKeepFor = Duration(days: 180);
const int kHistoryMaxEvents = 5000;

enum PlayKind { completed, skipped }

@immutable
class PlayEvent {
  const PlayEvent(this.songId, this.at, this.kind);

  factory PlayEvent.fromJson(Map<String, dynamic> json) => PlayEvent(
    json['id'] as String,
    DateTime.fromMillisecondsSinceEpoch((json['at'] as num).toInt()),
    json['kind'] == 'skipped' ? PlayKind.skipped : PlayKind.completed,
  );

  final String songId;
  final DateTime at;
  final PlayKind kind;

  Map<String, Object?> toJson() => {
    'id': songId,
    'at': at.millisecondsSinceEpoch,
    'kind': kind.name,
  };
}

/// What was played and skipped on this device, kept in one small JSON file.
class PlayHistory extends ChangeNotifier {
  PlayHistory(File file, {DateTime Function()? now})
    : _file = file,
      _now = now ?? DateTime.now;

  File _file;

  File get file => _file;
  final DateTime Function() _now;
  List<PlayEvent> _events = const [];
  Map<String, Song> _songs = const {};

  List<PlayEvent> get events => _events;
  Song? songFor(String songId) => _songs[songId];
  Iterable<Song> get songs => _songs.values;

  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return;
      _events = List.unmodifiable(
        (json['events'] as List<dynamic>).cast<Map<String, dynamic>>().map(
          PlayEvent.fromJson,
        ),
      );
      _songs = Map.unmodifiable({
        for (final raw
            in (json['songs'] as List<dynamic>).cast<Map<String, dynamic>>())
          raw['id'].toString(): Song.fromJson(raw),
      });
    } on Object catch (error) {
      // Losing history only makes suggestions less personal; it must not stop the app.
      debugPrint('Starting with empty play history: $error');
      _events = const [];
      _songs = const {};
    }
  }

  /// Switches to one account's history, so plays never mix between people on a device.
  /// [legacy] is the shared file from older versions, which the first account inherits.
  Future<void> openFor(File next, {File? legacy}) async {
    try {
      final old = legacy;
      if (old != null && !await next.exists() && await old.exists()) {
        await next.parent.create(recursive: true);
        await old.rename(next.path);
      }
    } on FileSystemException catch (error) {
      debugPrint('Could not move the old play history: $error');
    }
    _file = next;
    _events = const [];
    _songs = const {};
    await load();
    notifyListeners();
  }

  /// Forgets this account's history, on signing out.
  Future<void> clear() async {
    _events = const [];
    _songs = const {};
    try {
      if (await _file.exists()) await _file.delete();
    } on FileSystemException catch (error) {
      debugPrint('Could not delete the play history: $error');
    }
    notifyListeners();
  }

  Future<void> record(Song song, PlayKind kind, DateTime at) async {
    final cutoff = _now().subtract(kHistoryKeepFor);
    final kept = [
      ..._events.where((event) => event.at.isAfter(cutoff)),
      PlayEvent(song.id, at, kind),
    ];
    _events = List.unmodifiable(
      kept.length > kHistoryMaxEvents
          ? kept.skip(kept.length - kHistoryMaxEvents)
          : kept,
    );
    final liveIds = _events.map((event) => event.songId).toSet();
    _songs = Map.unmodifiable({
      for (final entry in _songs.entries)
        if (liveIds.contains(entry.key)) entry.key: entry.value,
      song.id: song,
    });
    await _save();
    notifyListeners();
  }

  /// Full listens of [songId] after [since].
  int fullPlaysSince(String songId, DateTime since) => _events
      .where(
        (event) =>
            event.songId == songId &&
            event.kind == PlayKind.completed &&
            event.at.isAfter(since),
      )
      .length;

  DateTime? lastPlayed(String songId) => _events
      .where((e) => e.songId == songId && e.kind == PlayKind.completed)
      .map((e) => e.at)
      .fold<DateTime?>(
        null,
        (latest, at) => latest == null || at.isAfter(latest) ? at : latest,
      );

  Future<void> _save() async {
    final temp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temp.writeAsString(
        jsonEncode({
          'events': [for (final event in _events) event.toJson()],
          'songs': [for (final song in _songs.values) song.toJson()],
        }),
      );
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save play history: $error');
    }
  }
}
