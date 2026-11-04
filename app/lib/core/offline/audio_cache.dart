import 'dart:io';

import 'audio_files.dart';

const Duration _recentlyTouched = Duration(minutes: 2);

/// Songs kept automatically after being played or preloaded, oldest dropped first
/// once the folder passes [maxBytes]. Downloads are separate and never evicted.
class AudioCache {
  AudioCache(this.directory, {required this.maxBytes});

  final Directory directory;
  int maxBytes;

  /// Where a song's copy goes, without extension (the fetcher adds the real one).
  File baseFor(String songId) =>
      File('${directory.path}/${safeFileId(songId)}');

  File? find(String songId) => findAudioFile(directory, songId);

  bool isCached(String songId) => find(songId) != null;

  /// Marks a song as just used, so it is evicted last.
  Future<void> touch(String songId) async {
    final file = find(songId);
    if (file != null) await file.setLastModified(DateTime.now());
  }

  Future<int> sizeBytes() async =>
      (await _audioFiles()).fold<int>(0, (sum, f) => sum + f.length);

  Future<List<_Item>> _audioFiles() async {
    if (!await directory.exists()) return const [];
    final items = <_Item>[];
    await for (final entity in directory.list()) {
      if (entity is File && hasAudioExtension(entity.path)) {
        final stat = await entity.stat();
        items.add(_Item(entity, stat.size, stat.modified));
      }
    }
    return items;
  }

  /// Removes files from older versions (the unplayable ".audio" copies) and any leftovers.
  Future<void> purgeLegacy() async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final path = entity.path;
      if (path.endsWith('.audio') ||
          path.endsWith('.mime') ||
          path.endsWith('.part') ||
          path.endsWith('.dl')) {
        await entity.delete();
      }
    }
  }

  /// Deletes least-recently-used songs until the cache fits. Returns how many were removed.
  Future<int> evict({Set<String> protect = const {}}) async {
    final items = await _audioFiles();
    var total = items.fold<int>(0, (sum, i) => sum + i.length);
    if (total <= maxBytes) return 0;
    items.sort((a, b) => a.modified.compareTo(b.modified));
    final now = DateTime.now();
    var removed = 0;
    for (final item in items) {
      if (total <= maxBytes) break;
      if (protect.any(
        (id) =>
            baseFor(id).path ==
            item.file.path.substring(0, item.file.path.lastIndexOf('.')),
      ))
        continue;
      if (now.difference(item.modified) < _recentlyTouched)
        continue; // probably playing right now
      await item.file.delete();
      total -= item.length;
      removed++;
    }
    return removed;
  }

  /// Deletes the cached copy of one song (used when a saved copy turns out to be unplayable).
  Future<void> remove(String songId) async {
    final file = find(songId);
    if (file != null) await file.delete();
  }

  Future<void> clear() async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File) await entity.delete();
    }
  }
}

class _Item {
  const _Item(this.file, this.length, this.modified);

  final File file;
  final int length;
  final DateTime modified;
}
