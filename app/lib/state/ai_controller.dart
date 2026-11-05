import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/ai/ai_api.dart';
import '../core/models.dart';

/// Songs sent per request when asking for labels.
const int _queueChunk = 1000;

/// Labels the AI has given your library. Everything is optional: without a key on the
/// server, or when the server's away, the app simply has no labels and carries on.
class AiController extends ChangeNotifier {
  AiController({required File file}) : _file = file;

  final File _file;
  AiApi? _api;
  Map<String, SongTag> _songs = const {};
  Map<String, List<String>> _similar = const {};
  String? _etag;
  bool _isAvailable = false;
  List<Song>? _lastQueued;

  /// Whether the server has AI features turned on.
  bool get isAvailable => _isAvailable;
  Map<String, List<String>> get similarArtists => _similar;

  SongTag? tagFor(Song song) => tagForNames(song.artist, song.title);

  SongTag? tagForNames(String artist, String title) =>
      _songs[songTagKey(artist, title)];

  /// Labels by song ID, for building Home.
  Map<String, SongTag> tagsById(Iterable<Song> songs) => {
    for (final song in songs)
      if (tagFor(song) case final tag?) song.id: tag,
  };

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final json =
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      _etag = json['etag'] as String?;
      _apply(json);
      notifyListeners();
    } on Object catch (error) {
      debugPrint('Ignoring saved labels: $error');
    }
  }

  void _apply(Map<String, dynamic> json) {
    _isAvailable = json['available'] == true;
    _songs = Map.unmodifiable({
      for (final entry
          in ((json['songs'] as Map<String, dynamic>?) ?? const {}).entries)
        entry.key: SongTag.fromJson(entry.value as Map<String, dynamic>),
    });
    _similar = Map.unmodifiable({
      for (final entry
          in ((json['artists'] as Map<String, dynamic>?) ?? const {}).entries)
        entry.key: List<String>.unmodifiable(
          (entry.value as List<dynamic>).whereType<String>(),
        ),
    });
  }

  void attach(AiApi? api) {
    _api = api;
    if (api == null) {
      _songs = const {};
      _similar = const {};
      _etag = null;
      _isAvailable = false;
      _lastQueued = null;
      unawaited(_delete());
      notifyListeners();
    } else {
      unawaited(refresh());
    }
  }

  Future<void> _delete() async {
    try {
      if (await _file.exists()) await _file.delete();
    } on FileSystemException catch (error) {
      debugPrint('Could not delete saved labels: $error');
    }
  }

  /// Fetches new labels, if there are any.
  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    try {
      final reply = await api.tags(etag: _etag);
      if (reply == null || !identical(api, _api)) return;
      final json = jsonDecode(reply.body) as Map<String, dynamic>;
      _etag = reply.etag;
      _apply(json);
      notifyListeners();
      await _save(json);
    } on Object catch (error) {
      debugPrint('Could not refresh labels: $error');
    }
  }

  Future<void> _save(Map<String, dynamic> json) async {
    try {
      final temp = File('${_file.path}.tmp');
      await temp.parent.create(recursive: true);
      await temp.writeAsString(jsonEncode({...json, 'etag': _etag}));
      await temp.rename(_file.path);
    } on Object catch (error) {
      debugPrint('Could not save labels: $error');
    }
  }

  /// Tells the server about songs it hasn't labelled yet.
  Future<void> queueMissing(List<Song> library) async {
    final api = _api;
    if (api == null || !_isAvailable || identical(library, _lastQueued)) return;
    _lastQueued = library;
    final seen = <String>{};
    final missing = <Map<String, String>>[
      for (final song in library)
        if (tagFor(song) == null &&
            seen.add(songTagKey(song.artist, song.title)))
          {
            'key': songTagKey(song.artist, song.title),
            'artist': song.artist,
            'title': song.title,
            'album': song.album,
            'genre': ?song.genre,
          },
    ];
    try {
      for (var at = 0; at < missing.length; at += _queueChunk) {
        final end = at + _queueChunk;
        await api.queueSongs(
          missing.sublist(at, end > missing.length ? missing.length : end),
        );
      }
    } on Object catch (error) {
      _lastQueued = null;
      debugPrint('Could not queue songs for labelling: $error');
    }
  }

  /// What a phrase means, or null if there's no answer. Never throws: this is only ever
  /// an extra on top of a search that already works.
  Future<SearchFilters?> interpret(String query) async {
    final api = _api;
    if (api == null || !_isAvailable) return null;
    try {
      final filters = await api.interpret(query);
      return filters.isEmpty ? null : filters;
    } on Object catch (error) {
      debugPrint('Could not interpret a search: $error');
      return null;
    }
  }
}
