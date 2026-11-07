import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/spotify/imported_playlist.dart';
import '../core/spotify/track_matcher.dart';

/// Playlists imported from elsewhere. Saved here first and on the server when it can be
/// reached, so they appear instantly, work offline, and reach your other devices.
class ImportsController extends ChangeNotifier {
  ImportsController({required File file}) : _file = file;

  final File _file;
  ImportsApi? _api;
  List<ImportedPlaylist> _playlists = const [];
  Set<String> _unsent = const {};
  Set<String> _deleted = const {};
  Future<void> _writes = Future.value();
  Future<void> _remoteWork = Future.value();
  int _generation = 0;

  Future<void> _serialize(Future<void> Function() action) {
    final next = _remoteWork.then((_) => action());
    _remoteWork = next.catchError((Object _) {});
    return next;
  }

  List<Song>? _matchedAgainst;

  List<ImportedPlaylist> get playlists => _playlists;

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final json =
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      _playlists = List.unmodifiable(
        (json['playlists'] as List<dynamic>).cast<Map<String, dynamic>>().map(
          ImportedPlaylist.fromJson,
        ),
      );
      _unsent = ((json['unsent'] as List<dynamic>?) ?? const [])
          .cast<String>()
          .toSet();
      _deleted = ((json['deleted'] as List<dynamic>?) ?? const [])
          .cast<String>()
          .toSet();
      notifyListeners();
    } on Object catch (error) {
      debugPrint('Ignoring saved imports: $error');
    }
  }

  Future<void> attach(ImportsApi? api) async {
    _generation++;
    _api = api;
    if (api == null) {
      _playlists = const [];
      _unsent = const {};
      _deleted = const {};
      _matchedAgainst = null;
      try {
        final deletion = _writes.then((_) async {
          if (await _file.exists()) await _file.delete();
        });
        _writes = deletion.catchError((Object _) {});
        await deletion;
      } on FileSystemException catch (error) {
        debugPrint('Could not delete saved imports: $error');
      }
      notifyListeners();
      return;
    }
    await sync();
  }

  /// Sends what's waiting, then takes in anything from other devices.
  Future<void> sync() {
    final api = _api;
    final generation = _generation;
    if (api == null) return Future.value();
    return _serialize(() async {
      if (generation != _generation) return;
      try {
        for (final id in _deleted.toList()) {
          await api.delete(id);
          if (generation != _generation) return;
          _deleted = {..._deleted}..remove(id);
          await _save();
        }
        for (final id in _unsent.toList()) {
          await _uploadNow(id, api, generation);
          if (generation != _generation) return;
        }
        final remote = await api.list();
        if (generation != _generation) return;
        final waiting = {
          for (final playlist in _playlists)
            if (_unsent.contains(playlist.id)) playlist.id: playlist,
        };
        _playlists = List.unmodifiable([
          ...waiting.values,
          ...remote.where(
            (p) => !waiting.containsKey(p.id) && !_deleted.contains(p.id),
          ),
        ]);
        await _save();
        if (generation == _generation) notifyListeners();
      } on Object catch (error) {
        debugPrint('Could not sync imported playlists: $error');
      }
    });
  }

  static String _newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Saves a reviewed playlist. It's yours from here, even if the server can't be reached.
  Future<ImportedPlaylist> add(String name, List<ImportEntry> entries) async {
    final playlist = ImportedPlaylist(
      id: _newId(),
      name: name,
      entries: List.unmodifiable(entries),
    );
    _playlists = List.unmodifiable([playlist, ..._playlists]);
    // Shown at once from the local copy; the server upload carries on behind it.
    await _store(playlist, waitForServer: false);
    return playlist;
  }

  Future<void> update(ImportedPlaylist playlist) async {
    _playlists = List.unmodifiable([
      for (final other in _playlists)
        if (other.id == playlist.id) playlist else other,
    ]);
    await _store(playlist);
  }

  Future<void> addSong(String playlistId, Song song) async {
    final playlist = _playlists.where((p) => p.id == playlistId).firstOrNull;
    if (playlist != null) await update(playlist.withSongAdded(song));
  }

  Future<void> remove(String id) async {
    final api = _api;
    final generation = _generation;
    _deleted = {..._deleted, id};
    _playlists = List.unmodifiable(_playlists.where((p) => p.id != id));
    _unsent = {..._unsent}..remove(id);
    await _save();
    if (generation != _generation) return;
    notifyListeners();
    if (api == null) return;
    await _serialize(() async {
      if (generation != _generation) return;
      try {
        await api.delete(id);
        if (generation != _generation) return;
        _deleted = {..._deleted}..remove(id);
        await _save();
      } on Object catch (error) {
        debugPrint('Could not delete an import from the server: $error');
      }
    });
  }

  Future<void> _store(
    ImportedPlaylist playlist, {
    bool waitForServer = true,
  }) async {
    final api = _api;
    final generation = _generation;
    _unsent = {..._unsent, playlist.id};
    await _save();
    if (generation != _generation) return;
    notifyListeners();
    if (api == null) return;
    final upload = _serialize(() => _uploadNow(playlist.id, api, generation));
    if (waitForServer) await upload;
  }

  Future<void> _uploadNow(String id, ImportsApi api, int generation) async {
    if (generation != _generation || _deleted.contains(id)) return;
    final playlist = _playlists.where((p) => p.id == id).firstOrNull;
    if (playlist == null) return;
    try {
      await api.save(playlist);
      if (generation != _generation) return;
      final current = _playlists.where((p) => p.id == id).firstOrNull;
      if (identical(current, playlist)) _unsent = {..._unsent}..remove(id);
      await _save();
    } on Object catch (error) {
      debugPrint('An imported playlist will be sent later: $error');
    }
  }

  /// After a library change, fills in songs that have now arrived.
  Future<void> rematch(List<Song> library) async {
    if (identical(library, _matchedAgainst) || _playlists.isEmpty) return;
    _matchedAgainst = library;
    final matcher = TrackMatcher(library);
    final generation = _generation;
    for (final playlist in _playlists) {
      if (generation != _generation) return;
      final next = playlist.rematched(matcher);
      if (!identical(next, playlist)) await update(next);
    }
  }

  /// Every song in every import, for keeping them offline.
  List<Song> songsIn(List<Song> library) {
    if (_playlists.isEmpty) return const [];
    final byId = {for (final song in library) song.id: song};
    return [
      for (final playlist in _playlists)
        for (final entry in playlist.entries)
          if (entry.songId case final id?) ?byId[id],
    ];
  }

  Future<void> _save() {
    final snapshot = jsonEncode({
      'playlists': [for (final p in _playlists) p.toJson()],
      'unsent': _unsent.toList(),
      'deleted': _deleted.toList(),
    });
    return _writes = _writes.then((_) => _write(snapshot));
  }

  Future<void> _write(String snapshot) async {
    try {
      final temp = File('${_file.path}.tmp');
      await temp.parent.create(recursive: true);
      await temp.writeAsString(snapshot);
      await temp.rename(_file.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save imports: $error');
    }
  }
}
