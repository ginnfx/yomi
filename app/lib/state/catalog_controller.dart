import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/search_index.dart';
import '../core/subsonic_client.dart';

const int _pageSize = 500;

/// Bumped when saved songs lack something newer versions need, so they're fetched again.
const int _savedFormat = 2;

/// How soon to look again when the server is partway through a library scan.
const Duration _rescanCheckAfter = Duration(seconds: 30);

/// Every song in the library, saved on this device.
///
/// Screens read [songs] directly, so the list is complete and instant. [sync] only asks
/// the server for songs again after a library scan, and swaps the list once it has all
/// of them, so nothing visibly reloads.
class CatalogController extends ChangeNotifier {
  CatalogController({required Directory directory}) : _directory = directory;

  final Directory _directory;
  SubsonicClient? _client;
  String? _accountId;
  List<Song> _songs = const [];
  String? _lastScan;
  bool _isLoaded = false;
  bool _isSyncing = false;
  Object? _error;
  int _generation = 0;

  Timer? _rescanCheck;
  Map<String, String>? _artistCovers;
  List<Song>? _artistCoversFrom;

  List<Song> get songs => _songs;

  /// The library scan [songs] came from. Changes when the library does.
  String? get lastScan => _lastScan;

  /// A cover to represent an artist, without asking the server.
  String? coverForArtist(String name) {
    if (!identical(_artistCoversFrom, _songs)) {
      _artistCoversFrom = _songs;
      _artistCovers = _firstCoverByArtist(_songs);
    }
    return _artistCovers?[name];
  }

  static Map<String, String> _firstCoverByArtist(List<Song> songs) {
    final covers = <String, String>{};
    for (final song in songs) {
      final cover = song.coverArtId;
      if (cover != null) covers.putIfAbsent(song.artist, () => cover);
    }
    return covers;
  }

  /// Search over [songs], rebuilt only after they change.
  SearchIndex get searchIndex {
    final built = _index;
    if (built != null && identical(_indexedSongs, _songs)) return built;
    _indexedSongs = _songs;
    return _index = SearchIndex(_songs);
  }

  SearchIndex? _index;
  List<Song>? _indexedSongs;

  /// Whether [songs] is the whole library, as opposed to nothing having been fetched yet.
  bool get isLoaded => _isLoaded;
  bool get isSyncing => _isSyncing;
  Object? get error => _error;

  File _fileFor(String account) => File('${_directory.path}/$account.json');

  /// Follows the signed-in client. The same account on a new address keeps everything.
  Future<void> attach(SubsonicClient? client, String? accountId) async {
    _client = client;
    if (accountId == _accountId) return;
    final previous = _accountId;
    _accountId = accountId;
    _rescanCheck?.cancel();
    _generation++;
    _songs = const [];
    _lastScan = null;
    _isLoaded = false;
    _error = null;
    notifyListeners();
    if (accountId == null) {
      if (previous != null) await _delete(previous);
      return;
    }
    await _read(accountId);
  }

  Future<void> _delete(String account) async {
    try {
      final file = _fileFor(account);
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint('Could not delete the saved song list: $error');
    }
  }

  Future<void> _read(String account) async {
    final generation = _generation;
    try {
      final file = _fileFor(account);
      if (!await file.exists()) return;
      final text = await file.readAsString();
      final saved = await Isolate.run(() => _decode(text));
      if (generation != _generation) return;
      _songs = saved.songs;
      _lastScan = saved.lastScan;
      _isLoaded = true;
      notifyListeners();
    } on Object catch (error) {
      // Only a saved copy: the next sync rebuilds it.
      debugPrint('Ignoring the saved song list: $error');
    }
  }

  /// Brings the list up to date if the library changed. Failures keep what's showing.
  Future<void> sync({bool force = false}) async {
    final client = _client;
    final account = _accountId;
    if (client == null || account == null || _isSyncing) return;
    final generation = _generation;
    _isSyncing = true;
    _error = null;
    notifyListeners();
    try {
      final status = await client.scanStatus();
      if (status.isScanning && _isLoaded && !force) {
        _rescanCheck?.cancel();
        _rescanCheck = Timer(_rescanCheckAfter, () => unawaited(sync()));
        return;
      }
      final isSameScan =
          _isLoaded && status.lastScan != null && status.lastScan == _lastScan;
      final songs = isSameScan && !force
          ? _songs
          : await _fetchAll(client, generation);
      if (songs == null || generation != _generation) return;
      final starred = {
        for (final song in await client.freshStarredSongs()) song.id,
      };
      if (generation != _generation) return;
      _songs = List.unmodifiable([
        for (final song in songs)
          song.isStarred == starred.contains(song.id)
              ? song
              : song.copyWith(isStarred: starred.contains(song.id)),
      ]);
      _lastScan = status.lastScan;
      _isLoaded = true;
      await _save(account, generation);
    } on Object catch (error) {
      if (generation == _generation) _error = error;
      debugPrint('Could not update the song list: $error');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<List<Song>?> _fetchAll(SubsonicClient client, int generation) async {
    final all = <Song>[];
    while (true) {
      final page = await client.freshSongs(
        offset: all.length,
        count: _pageSize,
      );
      if (generation != _generation) return null;
      all.addAll(page);
      if (page.length < _pageSize) return all;
    }
  }

  Future<void> _save(String account, int generation) async {
    final songs = _songs;
    final lastScan = _lastScan;
    try {
      final text = await Isolate.run(
        () => jsonEncode({
          'format': _savedFormat,
          'lastScan': lastScan,
          'songs': [for (final song in songs) song.toJson()],
        }),
      );
      // Signed out while encoding: this account's songs must not reappear on disk.
      if (generation != _generation) return;
      final file = _fileFor(account);
      final temp = File('${file.path}.tmp');
      await file.parent.create(recursive: true);
      await temp.writeAsString(text);
      if (generation != _generation) {
        await temp.delete();
        return;
      }
      await temp.rename(file.path);
    } on Object catch (error) {
      debugPrint('Could not save the song list: $error');
    }
  }

  @override
  void dispose() {
    _rescanCheck?.cancel();
    super.dispose();
  }

  static _SavedCatalog _decode(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    return _SavedCatalog(
      json['format'] == _savedFormat ? json['lastScan'] as String? : null,
      List<Song>.unmodifiable(
        (json['songs'] as List<dynamic>).cast<Map<String, dynamic>>().map(
          Song.fromJson,
        ),
      ),
    );
  }
}

@immutable
class _SavedCatalog {
  const _SavedCatalog(this.lastScan, this.songs);

  final String? lastScan;
  final List<Song> songs;
}
