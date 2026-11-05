import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../core/listening/history_api.dart';
import '../core/listening/play_history.dart';
import '../core/spotify/spotify_export.dart';

const int _uploadBatch = 500;

/// Every play, from this device and the others, plus anything imported from Spotify.
///
/// [PlayHistory] stays small because it feeds recommendations. This keeps everything,
/// for stats, and is what lets a new device start with your taste.
class ListeningLog extends ChangeNotifier {
  ListeningLog({required Directory directory, required this.history})
    : _directory = directory;

  final Directory _directory;
  final PlayHistory history;
  HistoryApi? _api;
  String? _account;
  Map<String, ListenEvent> _byId = const {};
  ImportedHistory _imported = ImportedHistory.empty();
  int _cursor = 0;
  int _uploadedUntilMs = 0;
  bool _isSyncing = false;
  bool _hasCheckedImported = false;

  List<ListenEvent> get events => _merged;
  List<ListenEvent> _merged = const [];
  ImportedHistory get imported => _imported;

  /// Plays made on other devices, for suggestions on this one.
  List<PlayEvent> get remotePlays {
    final cached = _remotePlays;
    if (cached != null && identical(_remotePlaysFrom, history.events)) {
      return cached;
    }
    final local = {for (final event in history.events) _idOf(event)};
    _remotePlaysFrom = history.events;
    return _remotePlays = List.unmodifiable([
      for (final event in _merged)
        if (!local.contains(event.id))
          PlayEvent(event.songId, event.at, event.kind),
    ]);
  }

  List<PlayEvent>? _remotePlays;
  List<PlayEvent>? _remotePlaysFrom;

  File _fileFor(String account) => File('${_directory.path}/log-$account.json');
  File _importedFileFor(String account) =>
      File('${_directory.path}/imported-$account.json');

  /// The same play gets the same ID wherever it's sent from, so retries can't double-count.
  static String _idOf(PlayEvent event) =>
      '${event.songId}:${event.at.millisecondsSinceEpoch}:${event.kind.name}';

  Future<void> attach(HistoryApi? api, String? account) async {
    _api = api;
    if (account == _account) return;
    final previous = _account;
    _account = account;
    _byId = const {};
    _merged = const [];
    _imported = ImportedHistory.empty();
    _cursor = 0;
    _uploadedUntilMs = 0;
    _hasCheckedImported = false;
    if (account == null) {
      if (previous != null) await _delete(previous);
    } else {
      await _read(account);
    }
    notifyListeners();
  }

  Future<void> _delete(String account) async {
    for (final file in [_fileFor(account), _importedFileFor(account)]) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException catch (error) {
        debugPrint('Could not delete saved plays: $error');
      }
    }
  }

  Future<void> _read(String account) async {
    try {
      final file = _fileFor(account);
      if (await file.exists()) {
        final text = await file.readAsString();
        final saved = await Isolate.run(() => _decode(text));
        _cursor = saved.cursor;
        _uploadedUntilMs = saved.uploadedUntilMs;
        _setEvents({for (final event in saved.events) event.id: event});
      }
      final importedFile = _importedFileFor(account);
      if (await importedFile.exists()) {
        final text = await importedFile.readAsString();
        _imported = await Isolate.run(
          () => ImportedHistory.fromJson(
            jsonDecode(text) as Map<String, dynamic>,
          ),
        );
      }
    } on Object catch (error) {
      // A saved copy only: the next sync rebuilds it from the server.
      debugPrint('Ignoring saved plays: $error');
    }
  }

  void _setEvents(Map<String, ListenEvent> byId) {
    _byId = byId;
    _remotePlays = null;
    _merged = List.unmodifiable(
      byId.values.toList()..sort((a, b) => a.at.compareTo(b.at)),
    );
  }

  /// Sends new plays and fetches ones from other devices. Failures just wait for next time.
  Future<void> sync() async {
    final api = _api;
    final account = _account;
    if (api == null || account == null || _isSyncing) return;
    _isSyncing = true;
    try {
      _addLocalPlays();
      await _upload(api);
      await _download(api);
      await _pullImported(api, account);
      if (account == _account) await _save(account);
    } on Object catch (error) {
      debugPrint('Could not sync listening history: $error');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  void _addLocalPlays() {
    final next = {..._byId};
    for (final event in history.events) {
      final song = history.songFor(event.songId);
      final id = _idOf(event);
      if (next.containsKey(id)) continue;
      next[id] = ListenEvent(
        id: id,
        songId: event.songId,
        artist: song?.artist ?? '',
        title: song?.title ?? '',
        album: song?.album ?? '',
        genre: song?.genre,
        at: event.at,
        kind: event.kind,
        seconds: event.kind == PlayKind.completed
            ? song?.durationSeconds ?? 0
            : 0,
      );
    }
    _setEvents(next);
  }

  /// Sends everything from the last upload's time on. Including that exact moment means a
  /// play in the same millisecond isn't missed; the server ignores what it already has.
  Future<void> _upload(HistoryApi api) async {
    final waiting = [
      for (final event in _merged)
        if (event.at.millisecondsSinceEpoch >= _uploadedUntilMs) event,
    ];
    for (var at = 0; at < waiting.length; at += _uploadBatch) {
      final end = at + _uploadBatch;
      final batch = waiting.sublist(
        at,
        end > waiting.length ? waiting.length : end,
      );
      await api.upload(batch);
      _uploadedUntilMs = batch.last.at.millisecondsSinceEpoch;
    }
  }

  Future<void> _download(HistoryApi api) async {
    while (true) {
      final page = await api.read(_cursor);
      // Going backwards means the server's log was replaced. It's lost what it had, so
      // everything goes up again on the next sync.
      if (page.next < _cursor) _uploadedUntilMs = 0;
      if (page.events.isEmpty && page.next == _cursor) return;
      _setEvents({..._byId, for (final event in page.events) event.id: event});
      final isDone = page.next == _cursor || page.events.isEmpty;
      _cursor = page.next;
      if (isDone) return;
    }
  }

  /// Fetches totals imported on another device, once each time the app opens.
  Future<void> _pullImported(HistoryApi api, String account) async {
    if (_hasCheckedImported) return;
    _hasCheckedImported = true;
    final json = await api.readImported();
    if (json['months'] == null) return;
    final remote = await Isolate.run(() => ImportedHistory.fromJson(json));
    if (account != _account || remote.seen.length <= _imported.seen.length) {
      return;
    }
    _imported = remote;
    await _saveImportedFile(account);
  }

  Future<void> _save(String account) async {
    final events = _merged;
    final cursor = _cursor;
    final uploaded = _uploadedUntilMs;
    await _write(
      _fileFor(account),
      await Isolate.run(
        () => jsonEncode({
          'cursor': cursor,
          'uploadedUntil': uploaded,
          'events': [for (final event in events) event.toJson()],
        }),
      ),
    );
  }

  Future<void> _saveImportedFile(String account) async {
    final imported = _imported;
    await _write(
      _importedFileFor(account),
      await Isolate.run(() => jsonEncode(imported.toJson())),
    );
  }

  Future<void> _write(File file, String text) async {
    try {
      final temp = File('${file.path}.tmp');
      await temp.parent.create(recursive: true);
      await temp.writeAsString(text);
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save plays: $error');
    }
  }

  /// Adds listens from a Spotify export. Saved here first, so it counts even if the
  /// server can't be reached yet. Returns how many new listens there were.
  Future<int> importSpotify(List<HistoryRow> rows) async {
    final account = _account;
    if (account == null) return 0;
    final before = _imported.seen.length;
    final current = _imported;
    final next = await Isolate.run(() => current.adding(rows));
    _imported = next;
    await _saveImportedFile(account);
    notifyListeners();
    try {
      final body = await Isolate.run(() => jsonEncode(next.toJson()));
      await _api?.saveImported(body);
    } on Object catch (error) {
      debugPrint('Could not send imported history to the server: $error');
    }
    return next.seen.length - before;
  }

  static _SavedLog _decode(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    return _SavedLog(
      cursor: (json['cursor'] as num?)?.toInt() ?? 0,
      uploadedUntilMs: (json['uploadedUntil'] as num?)?.toInt() ?? 0,
      events: (json['events'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(ListenEvent.fromJson)
          .toList(growable: false),
    );
  }
}

@immutable
class _SavedLog {
  const _SavedLog({
    required this.cursor,
    required this.uploadedUntilMs,
    required this.events,
  });

  final int cursor;
  final int uploadedUntilMs;
  final List<ListenEvent> events;
}
