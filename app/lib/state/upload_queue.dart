import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/subsonic_client.dart';
import '../core/upload/bulk_upload_api.dart';
import '../core/upload/file_inspector.dart';
import '../core/upload/library_snapshot.dart';

const int kConcurrentUploads = 2;
const int kCheckBatch = 200;
const int kMaxUploadAttempts = 3;
const Duration _saveEvery = Duration(seconds: 3);
const Duration _notifyEvery = Duration(milliseconds: 250);
const Duration kUnreachableRetryAfter = Duration(seconds: 30);

enum UploadState {
  /// Not looked at yet.
  queued,

  /// Inspected and clear to send.
  ready,
  uploading,
  done,

  /// Identical content already on the server or earlier in this queue. Never sent.
  duplicate,

  /// Same artist, title and length as a song in the library. Waits for a decision.
  likelyDuplicate,

  /// The user chose not to send a likely duplicate.
  skipped,
  failed,
}

@immutable
class UploadItem {
  const UploadItem({
    required this.path,
    required this.name,
    this.state = UploadState.queued,
    this.facts,
    this.size = 0,
    this.modifiedMs = 0,
    this.attempts = 0,
    this.error,
  });

  factory UploadItem.fromJson(Map<String, dynamic> json) => UploadItem(
    path: json['path'] as String,
    name: json['name'] as String,
    state: UploadState.values.byName(json['state'] as String),
    facts: json['facts'] == null
        ? null
        : FileFacts.fromJson(json['facts'] as Map<String, dynamic>),
    size: (json['size'] as num?)?.toInt() ?? 0,
    modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
    attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
  );

  final String path;
  final String name;
  final UploadState state;
  final FileFacts? facts;
  final int size;
  final int modifiedMs;
  final int attempts;
  final String? error;

  UploadItem copyWith({
    UploadState? state,
    FileFacts? facts,
    int? size,
    int? modifiedMs,
    int? attempts,
    String? error,
  }) => UploadItem(
    path: path,
    name: name,
    state: state ?? this.state,
    facts: facts ?? this.facts,
    size: size ?? this.size,
    modifiedMs: modifiedMs ?? this.modifiedMs,
    attempts: attempts ?? this.attempts,
    error: error,
  );

  Map<String, Object?> toJson() => {
    'path': path,
    'name': name,
    'state': state.name,
    'facts': facts?.toJson(),
    'size': size,
    'modifiedMs': modifiedMs,
    'attempts': attempts,
    'error': error,
  };
}

/// Why the queue has stopped by itself, if it has.
enum UploadPause {
  waitingForServer,
  signInAgain,
  storageFull,
  needsFolderAccess,

  /// Connected to the read-only backup server. Clears once the main one is back.
  onBackupServer,

  /// The server predates bulk uploads. Sending thousands of files the old way
  /// would run a full library scan for each one, so the queue waits instead.
  serverNeedsUpdate,
}

typedef FileInspector = Future<FileFacts> Function(String path);
typedef SnapshotLoader = Future<LibrarySnapshot?> Function();

/// A queue of songs to upload that survives the app being killed. Files are inspected in
/// the background and sent two at a time. Items are immutable; only this class's private
/// map changes, so a progress tick never copies thousands of entries.
class UploadQueue extends ChangeNotifier {
  UploadQueue({
    required this.queueFile,
    required this.hashCacheFile,
    FileInspector? inspector,
    this.retryAfterUnreachable = kUnreachableRetryAfter,
  }) : _inspector = inspector ?? inspectFile;

  final File queueFile;
  final File hashCacheFile;
  final FileInspector _inspector;
  final Duration retryAfterUnreachable;

  final Map<String, UploadItem> _items = {};
  final Map<String, double> _progress = {};
  final Map<String, FileFacts> _hashCache = {};
  UploadTransport? _transport;
  SnapshotLoader? _loadSnapshot;
  LibrarySnapshot? _snapshot;

  /// Songs this queue has already chosen to send. A batch is classified before any of it
  /// uploads, so the library alone can't catch two copies sitting in the same folder.
  final LibrarySnapshot _claimed = LibrarySnapshot(const []);
  bool _hasSeededClaims = false;
  bool _isRunning = false;
  bool _isDisposed = false;
  UploadPause? _pause;
  Timer? _resumeTimer;
  Timer? _saveTimer;
  Timer? _notifyTimer;
  DateTime _retryNotBefore = DateTime.fromMillisecondsSinceEpoch(0);

  List<UploadItem> get items => List.unmodifiable(_items.values);
  bool get isRunning => _isRunning;
  UploadPause? get pause => _pause;
  double progressOf(String path) => _progress[path] ?? 0;
  int count(UploadState state) =>
      _items.values.where((item) => item.state == state).length;
  int get total => _items.length;

  /// Files still to be dealt with automatically.
  int get remaining =>
      count(UploadState.queued) +
      count(UploadState.ready) +
      count(UploadState.uploading);

  Future<void> load() async {
    await _loadHashCache();
    try {
      if (!await queueFile.exists()) return;
      final json = jsonDecode(await queueFile.readAsString());
      if (json is! List<dynamic>) return;
      for (final raw in json.cast<Map<String, dynamic>>()) {
        final item = UploadItem.fromJson(raw);
        // Whatever was mid-flight when the app died starts again.
        _items[item.path] = item.state == UploadState.uploading
            ? item.copyWith(state: UploadState.ready)
            : item;
      }
    } on Object catch (error) {
      debugPrint('Starting with an empty upload queue: $error');
      _items.clear();
    }
  }

  /// Connects to a server, or disconnects with null, and picks up any unfinished work.
  void attach(UploadTransport? transport, {SnapshotLoader? loadSnapshot}) {
    _transport = transport;
    _loadSnapshot = loadSnapshot;
    if (transport == null) return;
    if (_pause == UploadPause.signInAgain) _pause = null;
    start();
  }

  /// Adds every audio file under [folder]. Returns how many were new.
  Future<int> addFolder(String folder) async {
    final found = <String>[];
    await for (final entity in Directory(
      folder,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File && hasUploadExtension(entity.path)) {
        found.add(entity.path);
      }
    }
    found.sort();
    return addFiles(found);
  }

  Future<int> addFiles(Iterable<String> paths) async {
    var added = 0;
    for (final path in paths) {
      final existing = _items[path];
      if (existing == null) {
        _items[path] = UploadItem(
          path: path,
          name: path.split(Platform.pathSeparator).last,
        );
        added++;
      }
    }
    // Choosing the folder again restores access to anything that lost it.
    if (_pause == UploadPause.needsFolderAccess) _pause = null;
    _changed(saveNow: true);
    start();
    return added;
  }

  /// Sends likely duplicates the user has decided are really different songs.
  void uploadAnyway(String path) {
    final item = _items[path];
    if (item == null) return;
    _items[path] = item.copyWith(state: UploadState.ready);
    _changed(saveNow: true);
    start();
  }

  void uploadAllLikelyAnyway() {
    for (final item in _items.values.toList()) {
      if (item.state == UploadState.likelyDuplicate) {
        _items[item.path] = item.copyWith(state: UploadState.ready);
      }
    }
    _changed(saveNow: true);
    start();
  }

  void skipLikely(String path) {
    final item = _items[path];
    if (item == null) return;
    _items[path] = item.copyWith(state: UploadState.skipped);
    _changed(saveNow: true);
  }

  void retryFailed() {
    for (final item in _items.values.toList()) {
      if (item.state == UploadState.failed) {
        _items[item.path] = item.copyWith(
          state: item.facts == null ? UploadState.queued : UploadState.ready,
          attempts: 0,
        );
      }
    }
    _pause = null;
    _changed(saveNow: true);
    start();
  }

  /// Resumes after a pause such as full storage.
  void resume() {
    _pause = null;
    _changed();
    start();
  }

  /// Forgets every finished item. Unfinished work stays.
  void clearFinished() {
    _items.removeWhere(
      (_, item) =>
          item.state == UploadState.done ||
          item.state == UploadState.duplicate ||
          item.state == UploadState.skipped,
    );
    _changed(saveNow: true);
  }

  /// Runs until nothing is left that can be done without the user.
  void start() {
    if (_isRunning || _transport == null || _pause != null || _isDisposed) {
      return;
    }
    if (remaining == 0) return;
    unawaited(_run());
  }

  Future<void> _run() async {
    _isRunning = true;
    _changed();
    try {
      await _prepareSnapshot();
      await Future.wait([
        _inspectLoop(),
        for (var i = 0; i < kConcurrentUploads; i++) _uploadWorker(),
      ]);
    } finally {
      _isRunning = false;
      await _save();
      _changed();
      _scheduleResumeIfWaiting();
    }
  }

  Future<void> _prepareSnapshot() async {
    if (_snapshot != null) return;
    try {
      _snapshot = await _loadSnapshot?.call();
    } on Object catch (error) {
      // Exact duplicates are still caught; only the softer check is lost.
      debugPrint('Could not load the library for duplicate checks: $error');
    }
  }

  bool get _canContinue => !_isDisposed && _pause == null && _transport != null;

  Future<void> _inspectLoop() async {
    final seen = {
      for (final item in _items.values)
        if (item.facts != null && item.state != UploadState.queued)
          item.facts!.sha256: item.path,
    };
    if (!_hasSeededClaims) {
      _hasSeededClaims = true;
      for (final item in _items.values) {
        if (_isClaimed(item.state)) _claim(item.facts);
      }
    }
    while (_canContinue) {
      final batch = _items.values
          .where((item) => item.state == UploadState.queued)
          .take(kCheckBatch)
          .toList();
      if (batch.isEmpty) return;
      final inspected = <UploadItem>[];
      for (final item in batch) {
        if (!_canContinue) return;
        final result = await _inspectOne(item);
        if (result != null) inspected.add(result);
      }
      await _classify(inspected, seen);
    }
  }

  Future<UploadItem?> _inspectOne(UploadItem item) async {
    try {
      final stat = await File(item.path).stat();
      if (stat.type == FileSystemEntityType.notFound) {
        _fail(item, 'This file is no longer there.');
        return null;
      }
      final modifiedMs = stat.modified.millisecondsSinceEpoch;
      final key = '${item.path}|${stat.size}|$modifiedMs';
      final facts = _hashCache[key] ?? await _inspector(item.path);
      _hashCache[key] = facts;
      return item.copyWith(
        facts: facts,
        size: stat.size,
        modifiedMs: modifiedMs,
      );
    } on FileSystemException catch (error) {
      debugPrint('Cannot read ${item.path}: $error');
      _pause = UploadPause.needsFolderAccess;
      _changed(saveNow: true);
      return null;
    }
  }

  Future<void> _classify(
    List<UploadItem> inspected,
    Map<String, String> seen,
  ) async {
    if (inspected.isEmpty) return;
    final known = await _knownHashes(inspected);
    if (known == null) return;
    for (final item in inspected) {
      final facts = item.facts!;
      final isExact =
          known.contains(facts.sha256) || seen.containsKey(facts.sha256);
      final UploadState state;
      if (isExact) {
        state = UploadState.duplicate;
      } else if (_isLikelyDuplicate(facts)) {
        state = UploadState.likelyDuplicate;
      } else {
        state = UploadState.ready;
        _claim(facts);
      }
      seen[facts.sha256] = item.path;
      _items[item.path] = item.copyWith(state: state);
    }
    await _saveHashCache();
    _changed(saveNow: true);
  }

  /// Null means the check couldn't happen and the queue has paused.
  Future<Set<String>?> _knownHashes(List<UploadItem> items) async {
    final transport = _transport;
    if (transport == null) return null;
    try {
      return await transport.check([
        for (final item in items) item.facts!.sha256,
      ]);
    } on UploadRouteMissing {
      _pause = UploadPause.serverNeedsUpdate;
    } on UploadAuthFailed {
      _pause = UploadPause.signInAgain;
    } on UploadUnreachable {
      _pause = UploadPause.waitingForServer;
    } on UploadRetryLater catch (wait) {
      await Future<void>.delayed(wait.after);
      return _knownHashes(items);
    } on UploadRejected catch (error) {
      debugPrint('Duplicate check refused: $error');
      _pause = UploadPause.waitingForServer;
    }
    _changed(saveNow: true);
    return null;
  }

  UploadItem? _nextReady() {
    for (final item in _items.values) {
      if (item.state == UploadState.ready) return item;
    }
    return null;
  }

  Future<void> _uploadWorker() async {
    while (_canContinue) {
      final now = DateTime.now();
      if (now.isBefore(_retryNotBefore)) {
        await Future<void>.delayed(_retryNotBefore.difference(now));
        continue;
      }
      final next = _nextReady();
      if (next == null) {
        if (count(UploadState.queued) == 0) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      _items[next.path] = next.copyWith(state: UploadState.uploading);
      _changed();
      await _send(next);
    }
  }

  Future<void> _send(UploadItem item) async {
    final transport = _transport;
    if (transport == null) {
      _items[item.path] = item.copyWith(state: UploadState.ready);
      return;
    }
    void onProgress(double progress) {
      _progress[item.path] = progress;
      _changed();
    }

    try {
      final result = await transport.put(
        File(item.path),
        sha256: item.facts!.sha256,
        name: item.name,
        onProgress: onProgress,
      );
      _items[item.path] = item.copyWith(
        state: result == PutResult.duplicate
            ? UploadState.duplicate
            : UploadState.done,
      );
      _rememberInSnapshot(item);
    } on UploadRouteMissing {
      _pause = UploadPause.serverNeedsUpdate;
      _items[item.path] = item.copyWith(state: UploadState.ready);
    } on UploadRetryLater catch (wait) {
      _retryNotBefore = DateTime.now().add(wait.after);
      _items[item.path] = item.copyWith(state: UploadState.ready);
    } on UploadUnreachable {
      _pause = UploadPause.waitingForServer;
      _items[item.path] = item.copyWith(state: UploadState.ready);
    } on UploadAuthFailed {
      _pause = UploadPause.signInAgain;
      _items[item.path] = item.copyWith(state: UploadState.ready);
    } on UploadReadOnly {
      _pause = UploadPause.onBackupServer;
      _items[item.path] = item.copyWith(state: UploadState.ready);
    } on UploadStorageFull {
      _pause = UploadPause.storageFull;
      _items[item.path] = item.copyWith(state: UploadState.ready);
    } on UploadCorrupted {
      _retryOrFail(item, 'The file kept arriving damaged.');
    } on UploadRejected catch (error) {
      _fail(item, error.message);
    } on FileSystemException catch (error) {
      debugPrint('Cannot read ${item.path}: $error');
      _pause = UploadPause.needsFolderAccess;
      _items[item.path] = item.copyWith(state: UploadState.ready);
    } on Object catch (error) {
      // Nothing unexpected may strand a file as "uploading" or end this worker.
      debugPrint('Unexpected upload failure for ${item.name}: $error');
      _retryOrFail(item, 'Something went wrong sending this file.');
    } finally {
      _progress.remove(item.path);
      _changed(saveNow: true);
    }
  }

  static bool _isClaimed(UploadState state) =>
      state == UploadState.ready ||
      state == UploadState.uploading ||
      state == UploadState.done;

  bool _isLikelyDuplicate(FileFacts facts) =>
      (_snapshot?.hasLikelyMatch(
            facts.artist,
            facts.title,
            facts.durationSeconds,
          ) ??
          false) ||
      _claimed.hasLikelyMatch(facts.artist, facts.title, facts.durationSeconds);

  void _claim(FileFacts? facts) {
    final artist = facts?.artist;
    final title = facts?.title;
    if (artist == null || title == null) return;
    _claimed.add(artist, title, facts!.durationSeconds);
  }

  void _rememberInSnapshot(UploadItem item) {
    final facts = item.facts;
    final artist = facts?.artist;
    final title = facts?.title;
    if (artist == null || title == null) return;
    _snapshot?.add(artist, title, facts!.durationSeconds);
  }

  void _retryOrFail(UploadItem item, String message) {
    final attempts = item.attempts + 1;
    _items[item.path] = attempts >= kMaxUploadAttempts
        ? item.copyWith(
            state: UploadState.failed,
            attempts: attempts,
            error: message,
          )
        : item.copyWith(state: UploadState.ready, attempts: attempts);
  }

  void _fail(UploadItem item, String message) {
    _items[item.path] = item.copyWith(
      state: UploadState.failed,
      error: message,
    );
    _changed(saveNow: true);
  }

  void _scheduleResumeIfWaiting() {
    _resumeTimer?.cancel();
    final canClearByItself =
        _pause == UploadPause.waitingForServer ||
        _pause == UploadPause.onBackupServer;
    if (!canClearByItself || _isDisposed) return;
    _resumeTimer = Timer(retryAfterUnreachable, () {
      if (_pause == UploadPause.waitingForServer ||
          _pause == UploadPause.onBackupServer) {
        resume();
      }
    });
  }

  void _changed({bool saveNow = false}) {
    if (_isDisposed) return;
    _notifyTimer ??= Timer(_notifyEvery, () {
      _notifyTimer = null;
      if (!_isDisposed) notifyListeners();
    });
    if (saveNow) {
      _saveTimer ??= Timer(_saveEvery, () {
        _saveTimer = null;
        unawaited(_save());
      });
    }
  }

  /// Writes the queue now. Otherwise saving is batched, so a kill can lose a few
  /// seconds of progress; the server's duplicate check makes that harmless.
  Future<void> save() => _save();

  Future<void> _save() => _writeAtomically(
    queueFile,
    jsonEncode([for (final item in _items.values) item.toJson()]),
  );

  Future<void> _saveHashCache() => _writeAtomically(
    hashCacheFile,
    jsonEncode({
      for (final entry in _hashCache.entries) entry.key: entry.value.toJson(),
    }),
  );

  Future<void> _loadHashCache() async {
    try {
      if (!await hashCacheFile.exists()) return;
      final json = jsonDecode(await hashCacheFile.readAsString());
      if (json is! Map<String, dynamic>) return;
      for (final entry in json.entries) {
        _hashCache[entry.key] = FileFacts.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    } on Object catch (error) {
      debugPrint('Discarding the saved file hashes: $error');
      _hashCache.clear();
    }
  }

  Future<void> _writeAtomically(File file, String contents) async {
    final temp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temp.writeAsString(contents);
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save ${file.path}: $error');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _resumeTimer?.cancel();
    _saveTimer?.cancel();
    _notifyTimer?.cancel();
    super.dispose();
  }
}

/// The snapshot loader used by the app.
SnapshotLoader snapshotLoaderFor(SubsonicClient client) =>
    () => LibrarySnapshot.load(client);
