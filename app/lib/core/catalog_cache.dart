import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// A saved server response and whether it still counts as current.
@immutable
class CatalogEntry {
  const CatalogEntry({required this.data, required this.isFresh});

  final Map<String, dynamic> data;
  final bool isFresh;
}

/// Saved server responses for one account, kept in memory and in one file.
///
/// It belongs to the account rather than a server address, so moving between home, away
/// and tunnel routes keeps everything. Reads are synchronous once [load] has finished,
/// which is what lets a screen show real data on its first frame.
class CatalogCache {
  CatalogCache({
    required File file,
    DateTime Function()? now,
    this.maxEntries = defaultMaxEntries,
  }) : _file = file,
       _now = now ?? DateTime.now;

  static const int defaultMaxEntries = 128;

  /// How long an entry is shown without also being refreshed in the background.
  static const Duration freshFor = Duration(minutes: 5);

  final File _file;
  final DateTime Function() _now;
  final int maxEntries;

  final LinkedHashMap<String, _Saved> _entries = LinkedHashMap();
  final StreamController<String> _updates = StreamController.broadcast();
  Future<void>? _loading;
  Future<void>? _writing;
  bool _isDirty = false;

  /// The endpoint name of each entry as it changes.
  Stream<String> get updates => _updates.stream;

  /// Reads the saved file. Safe to call repeatedly; only the first call does any work.
  Future<void> load() => _loading ??= _readFile();

  Future<void> _readFile() async {
    try {
      if (!_file.existsSync()) return;
      final text = await _file.readAsString();
      final decoded = await Isolate.run(() => _decode(text));
      _entries.addAll(decoded);
    } on Object catch (error) {
      // Only a cache: start empty and it fills again from the server.
      debugPrint('Could not read the saved catalog: $error');
    }
  }

  CatalogEntry? peek(String endpoint, Map<String, Object?> params) {
    final saved = _entries[_keyFor(endpoint, params)];
    if (saved == null) return null;
    final age = _now().millisecondsSinceEpoch - saved.atMs;
    return CatalogEntry(
      data: saved.data,
      isFresh: age >= 0 && age < freshFor.inMilliseconds,
    );
  }

  void put(
    String endpoint,
    Map<String, Object?> params,
    Map<String, dynamic> data,
  ) {
    final key = _keyFor(endpoint, params);
    _entries.remove(key); // Re-adding moves it to the newest position.
    _entries[key] = _Saved(endpoint, _now().millisecondsSinceEpoch, data);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _changed();
    _updates.add(endpoint);
  }

  /// Forgets every entry from these endpoints.
  void remove(Set<String> endpoints) {
    _entries.removeWhere((_, saved) => endpoints.contains(saved.endpoint));
    _changed();
    endpoints.forEach(_updates.add);
  }

  /// Keeps showing what's saved, but refreshes each entry the next time it's read.
  void markAllStale() {
    final stale = _entries.map(
      (key, saved) => MapEntry(key, saved.withTime(0)),
    );
    _entries
      ..clear()
      ..addAll(stale);
    _changed();
  }

  /// Waits until everything so far is on disk.
  Future<void> flush() async {
    while (_writing != null) {
      await _writing;
    }
  }

  Future<void> clear() async {
    _entries.clear();
    _isDirty = false;
    await flush();
    try {
      if (_file.existsSync()) await _file.delete();
    } on Object catch (error) {
      debugPrint('Could not delete the saved catalog: $error');
    }
  }

  void _changed() {
    _isDirty = true;
    _writing ??= _writeLoop();
  }

  /// One write at a time; changes made during a write are picked up by the next pass.
  Future<void> _writeLoop() async {
    try {
      while (_isDirty) {
        _isDirty = false;
        final snapshot = {
          for (final entry in _entries.entries) entry.key: entry.value.toJson(),
        };
        final text = await Isolate.run(() => jsonEncode(snapshot));
        final temp = File('${_file.path}.tmp');
        await temp.parent.create(recursive: true);
        await temp.writeAsString(text, flush: true);
        await temp.rename(_file.path);
      }
    } on Object catch (error) {
      debugPrint('Could not save the catalog: $error');
    } finally {
      _writing = null;
    }
  }

  static String _keyFor(String endpoint, Map<String, Object?> params) =>
      jsonEncode([endpoint, params]);

  static Map<String, _Saved> _decode(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return const {};
    final result = <String, _Saved>{};
    for (final entry in decoded.entries) {
      final saved = _Saved.tryParse(entry.value);
      if (saved != null) result[entry.key as String] = saved;
    }
    return result;
  }
}

@immutable
class _Saved {
  const _Saved(this.endpoint, this.atMs, this.data);

  final String endpoint;
  final int atMs;
  final Map<String, dynamic> data;

  _Saved withTime(int atMs) => _Saved(endpoint, atMs, data);

  Map<String, Object?> toJson() => {
    'endpoint': endpoint,
    'at': atMs,
    'data': data,
  };

  static _Saved? tryParse(Object? json) {
    if (json is! Map) return null;
    final endpoint = json['endpoint'];
    final at = json['at'];
    final data = json['data'];
    if (endpoint is! String || at is! int || data is! Map) return null;
    return _Saved(endpoint, at, Map<String, dynamic>.from(data));
  }
}
