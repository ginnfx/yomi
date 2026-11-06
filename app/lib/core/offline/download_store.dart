import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'audio_files.dart';
import 'file_fetcher.dart';

/// Remembers which songs are saved for offline play. Lives in [directory] as
/// `index.json` plus one audio file per song, so it still works with no server.
class DownloadStore {
  DownloadStore(this.directory);

  final Directory directory;
  final Map<String, _Entry> _entries = {};

  File get _indexFile => File('${directory.path}/index.json');

  Future<void> load() async {
    await directory.create(recursive: true);
    _entries.clear();
    if (!await _indexFile.exists()) return;
    var changed = false;
    try {
      final decoded = jsonDecode(await _indexFile.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      for (final value in decoded.values) {
        try {
          if (value is! Map<String, dynamic>) throw const FormatException();
          final entry = _Entry.fromJson(value);
          final fixed = await _resolveFile(entry);
          if (fixed == null) {
            changed = true; // the audio file is gone
            continue;
          }
          if (fixed.fileName != entry.fileName) changed = true;
          _entries[fixed.song.id] = fixed;
        } on Object {
          changed = true; // a damaged entry is dropped, the rest stay
        }
      }
    } on Object {
      // A damaged index only means downloads must be repeated; never crash the app.
    }
    if (changed) await _save();
  }

  /// Older versions saved files as "<id>.audio", which iOS cannot play. Rename them to
  /// their real type so existing downloads start working.
  Future<_Entry?> _resolveFile(_Entry entry) async {
    final named = File('${directory.path}/${entry.fileName}');
    if (entry.fileName.isNotEmpty &&
        hasAudioExtension(entry.fileName) &&
        await named.exists())
      return entry;
    final legacy = File('${directory.path}/${safeFileId(entry.song.id)}.audio');
    if (await legacy.exists()) {
      final extension = await sniffFile(legacy);
      if (extension == null) {
        await legacy.delete();
        return null;
      }
      final renamed = '${safeFileId(entry.song.id)}.$extension';
      await legacy.rename('${directory.path}/$renamed');
      return entry.withFileName(renamed);
    }
    final found = findAudioFile(directory, entry.song.id);
    return found == null
        ? null
        : entry.withFileName(found.uri.pathSegments.last);
  }

  /// Where a song's file goes, without extension (the fetcher adds the real one).
  File baseFor(String songId) =>
      File('${directory.path}/${safeFileId(songId)}');

  File? fileFor(String songId) {
    final entry = _entries[songId];
    return entry == null ? null : File('${directory.path}/${entry.fileName}');
  }

  bool contains(String songId) => _entries.containsKey(songId);

  /// Newest first.
  List<Song> get songs {
    final sorted = _entries.values.toList()
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return List.unmodifiable(sorted.map((e) => e.song));
  }

  int bytesOf(String songId) => _entries[songId]?.bytes ?? 0;

  int get totalBytes => _entries.values.fold(0, (sum, e) => sum + e.bytes);

  Future<void> add(Song song, FetchedFile fetched) async {
    _entries[song.id] = _Entry(
      song,
      fetched.bytes,
      DateTime.now(),
      fetched.file.uri.pathSegments.last,
    );
    await _save();
  }

  Future<void> remove(String songId) async {
    final file = fileFor(songId);
    _entries.remove(songId);
    if (file != null && await file.exists()) await file.delete();
    await _save();
  }

  Future<void> removeAll() async {
    for (final id in _entries.keys.toList()) {
      final file = fileFor(id);
      if (file != null && await file.exists()) await file.delete();
    }
    _entries.clear();
    await _save();
  }

  Future<void> _saveQueue = Future.value();

  Future<void> _save() {
    final next = _saveQueue.then((_) => _writeIndex());
    _saveQueue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _writeIndex() async {
    final temp = File('${_indexFile.path}.tmp');
    await temp.writeAsString(
      jsonEncode({for (final e in _entries.entries) e.key: e.value.toJson()}),
    );
    await temp.rename(_indexFile.path);
  }
}

class _Entry {
  const _Entry(this.song, this.bytes, this.savedAt, this.fileName);

  factory _Entry.fromJson(Map<String, dynamic> json) => _Entry(
    Song.fromJson(json['song'] as Map<String, dynamic>),
    (json['bytes'] as num?)?.toInt() ?? 0,
    DateTime.tryParse(json['savedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    json['fileName'] as String? ?? '',
  );

  final Song song;
  final int bytes;
  final DateTime savedAt;
  final String fileName;

  _Entry withFileName(String name) => _Entry(song, bytes, savedAt, name);

  Map<String, Object?> toJson() => {
    'song': song.toJson(),
    'bytes': bytes,
    'savedAt': savedAt.toIso8601String(),
    'fileName': fileName,
  };
}
