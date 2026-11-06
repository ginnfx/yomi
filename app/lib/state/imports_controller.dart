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
      notifyListeners();
    } on Object catch (error) {
      debugPrint('Ignoring saved imports: $error');
    }
  }

  Future<void> attach(ImportsApi? api) async {
    _api = api;
    if (api == null) {
      _playlists = const [];
      _unsent = const {};
      _matchedAgainst = null;
      try {
        if (await _file.exists()) await _file.delete();
      } on FileSystemException catch (error) {
        debugPrint('Could not delete saved imports: $error');
      }
      notifyListeners();
      return;
    }
    await sync();
  }

  /// Sends what's waiting, then takes in anything from other devices.
  Future<void> sync() async {
    final api = _api;
    if (api == null) return;
    try {
      for (final id in _unsent.toList()) {
        final playlist = _playlists.where((p) => p.id == id).firstOrNull;
        if (playlist != null) await api.save(playlist);
        _unsent = {..._unsent}..remove(id);
      }
      final remote = await api.list();
      if (!identical(api, _api)) return;
      final waiting = {
        for (final playlist in _playlists)
          if (_unsent.contains(playlist.id)) playlist.id: playlist,
      };
      _playlists = List.unmodifiable([
        ...waiting.values,
        ...remote.where((p) => !waiting.containsKey(p.id)),
      ]);
      await _save();
      notifyListeners();
    } on Object catch (error) {
      debugPrint('Could not sync imported playlists: $error');
    }
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

  Future<void> remove(String id) async {
    _playlists = List.unmodifiable(_playlists.where((p) => p.id != id));
    _unsent = {..._unsent}..remove(id);
    await _save();
    notifyListeners();
    try {
      await _api?.delete(id);
    } on Object catch (error) {
      debugPrint('Could not delete an import from the server: $error');
    }
  }

  Future<void> _store(
    ImportedPlaylist playlist, {
    bool waitForServer = true,
  }) async {
    _unsent = {..._unsent, playlist.id};
    await _save();
    notifyListeners();
    final upload = _upload(playlist);
    if (waitForServer) await upload;
  }

  Future<void> _upload(ImportedPlaylist playlist) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.save(playlist);
      _unsent = {..._unsent}..remove(playlist.id);
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
    for (final playlist in _playlists) {
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

  Future<void> _save() async {
    try {
      final temp = File('${_file.path}.tmp');
      await temp.parent.create(recursive: true);
      await temp.writeAsString(
        jsonEncode({
          'playlists': [for (final p in _playlists) p.toJson()],
          'unsent': _unsent.toList(),
        }),
      );
      await temp.rename(_file.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save imports: $error');
    }
  }
}
