import 'package:flutter/foundation.dart';

/// A song Yomi would like to keep on the device for a kept playlist.
@immutable
class KeepCandidate {
  const KeepCandidate({
    required this.id,
    required this.bytes,
    required this.isSaved,
    this.lastPlayed,
  });

  final String id;

  /// Exact when saved, otherwise a guess from its length.
  final int bytes;
  final bool isSaved;
  final DateTime? lastPlayed;
}

/// What to do so kept songs fit the storage limit.
@immutable
class StoragePlan {
  const StoragePlan({
    required this.fetch,
    required this.evict,
    required this.isLimited,
  });

  final List<String> fetch;
  final List<String> evict;

  /// True when something wanted didn't fit, so the app can say why it's incomplete.
  final bool isLimited;
}

/// Works out which kept songs fit within [capBytes].
///
/// [wanted] is in priority order for songs never played. Songs played most recently come
/// first, and everything beyond the first song that doesn't fit is left out, so filling up
/// stops rather than churns: a song removed here stays lower in the order than what
/// replaced it, and can't be downloaded back straight away. [protect] stays regardless,
/// and [unwanted] are saved songs no longer in any kept playlist.
StoragePlan planKeptSongs({
  required int capBytes,
  required List<KeepCandidate> wanted,
  List<String> unwanted = const [],
  Set<String> protect = const {},
}) {
  final indexed = wanted.indexed.toList();
  indexed.sort((a, b) {
    final aPlayed = a.$2.lastPlayed;
    final bPlayed = b.$2.lastPlayed;
    if (aPlayed != null && bPlayed != null) {
      final byTime = bPlayed.compareTo(aPlayed);
      if (byTime != 0) return byTime;
    } else if (aPlayed != null) {
      return -1;
    } else if (bPlayed != null) {
      return 1;
    }
    return a.$1.compareTo(b.$1);
  });
  var used = 0;
  for (final (_, song) in indexed) {
    if (protect.contains(song.id) && song.isSaved) used += song.bytes;
  }
  final fetch = <String>[];
  final evict = <String>[...unwanted.where((id) => !protect.contains(id))];
  var isFull = false;
  for (final (_, song) in indexed) {
    final isProtected = protect.contains(song.id) && song.isSaved;
    if (isProtected) continue;
    if (!isFull && used + song.bytes <= capBytes) {
      used += song.bytes;
      if (!song.isSaved) fetch.add(song.id);
      continue;
    }
    isFull = true;
    if (song.isSaved) evict.add(song.id);
  }
  return StoragePlan(fetch: fetch, evict: evict, isLimited: isFull);
}
