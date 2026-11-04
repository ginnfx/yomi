import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/listening/play_history.dart';
import '../core/models.dart';
import '../core/recommendations.dart';
import '../core/subsonic_client.dart';
import 'settings.dart';

/// How many tiles sit at the top of Home.
const int quickPickCount = 6;
const int _libraryPoolSize = 200;
const int _recentCount = 16;

/// Keeps Home's shelves. They're saved to disk so Home opens instantly and offline, and
/// only rebuilt when the rotation key changes: a new day, or enough new plays.
class HomeController extends ChangeNotifier {
  HomeController({
    required this.history,
    required this.settings,
    required this.cacheFile,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    history.addListener(_onHistoryChanged);
    settings.addListener(_onSettingsChanged);
  }

  final PlayHistory history;
  final SettingsController settings;
  final File cacheFile;
  final DateTime Function() _now;
  SubsonicClient? _client;
  List<HomeShelf> _shelves = const [];
  List<Playlist> _quickPlaylists = const [];
  List<Song> _quickSongs = const [];
  _HomeContent? _heldBack;
  String? _builtFor;
  bool _isLoading = false;
  Future<void>? _inFlight;
  int _generation = 0;
  Object? _error;

  bool get isLoading => _isLoading;

  /// The top of Home. Saved with the shelves, so these stay put when the app reopens.
  List<Playlist> get quickPlaylists => _quickPlaylists;
  List<Song> get quickSongs => _quickSongs;
  Object? get error => _error;

  /// Shelves to show, minus any the user has hidden.
  List<HomeShelf> get shelves {
    final hidden = settings.hiddenHomeSections;
    return List.unmodifiable(
      _shelves.where((shelf) => !hidden.contains(shelf.kind.name)),
    );
  }

  String get _currentKey => homeRotationKey(_now(), history.events.length);

  Future<void> loadCache() async {
    try {
      if (!await cacheFile.exists()) return;
      final json = jsonDecode(await cacheFile.readAsString());
      if (json is! Map<String, dynamic>) return;
      _builtFor = json['key'] as String?;
      _shelves = List.unmodifiable(
        (json['shelves'] as List<dynamic>).cast<Map<String, dynamic>>().map(
          HomeShelf.fromJson,
        ),
      );
      _quickPlaylists = List.unmodifiable(
        ((json['quickPlaylists'] as List<dynamic>?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(Playlist.fromJson),
      );
      _quickSongs = List.unmodifiable(
        ((json['quickSongs'] as List<dynamic>?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(Song.fromJson),
      );
      notifyListeners();
    } on Object catch (error) {
      // Home simply rebuilds; a damaged cache costs nothing else.
      debugPrint('Ignoring saved Home: $error');
      _builtFor = null;
      _shelves = const [];
    }
  }

  void attach(SubsonicClient? client) {
    final isNewClient = !identical(client, _client);
    _client = client;
    if (client == null) {
      _shelves = const [];
      _quickPlaylists = const [];
      _quickSongs = const [];
      _heldBack = null;
      _builtFor = null;
      _generation++;
      // The next person to sign in on this device shouldn't see this Home.
      unawaited(_deleteCache());
      notifyListeners();
    } else if (isNewClient) {
      unawaited(refreshIfDue());
    }
  }

  void _onHistoryChanged() => unawaited(refreshIfDue());

  void _onSettingsChanged() => notifyListeners();

  /// Prepares a new Home if one is due. If Home is already showing, the new version is
  /// saved but held back until [applyHeldBack], so nothing changes under your finger.
  Future<void> refreshIfDue() async {
    if (_builtFor == _currentKey && _shelves.isNotEmpty) return;
    await _startRebuild(showNow: _shelves.isEmpty);
  }

  /// Rebuilds Home now, or joins a rebuild already running, because you asked for it. On
  /// failure the shelves already showing stay.
  Future<void> refresh() async {
    await _startRebuild(showNow: true);
    applyHeldBack();
  }

  Future<void> _startRebuild({required bool showNow}) =>
      _inFlight ??= _rebuild(showNow: showNow).whenComplete(() {
        _inFlight = null;
      });

  /// Shows a version of Home that was prepared in the background. Called when the app
  /// comes back after a while away.
  void applyHeldBack() {
    final held = _heldBack;
    if (held == null) return;
    _heldBack = null;
    _show(held);
    notifyListeners();
  }

  void _show(_HomeContent content) {
    _shelves = content.shelves;
    _quickPlaylists = content.playlists;
    _quickSongs = content.songs;
  }

  Future<void> _rebuild({required bool showNow}) async {
    final client = _client;
    if (client == null) return;
    final generation = _generation;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final results = await Future.wait<List<Song>>([
        client.randomSongs(size: _libraryPoolSize),
        client.recentSongs(count: _recentCount),
        client.starredSongs(),
      ]);
      final playlists = await _quickPlaylistsFrom(client);
      if (generation != _generation)
        return; // Signed out while this was loading.
      final key = _currentKey;
      final order = settings.hasCustomHomeOrder
          ? [
              for (final id in settings.homeOrder)
                ?ShelfKind.values.asNameMap()[id],
            ]
          : null;
      final shelves = HomeBuilder(
        events: history.events,
        pool: {
          for (final song in [...history.songs, ...results[0], ...results[2]])
            song.id: song,
        }.values.toList(),
        recentlyAdded: results[1],
        starred: {for (final song in results[2]) song.id},
        now: _now(),
      ).build(keepOrder: order);
      final content = _HomeContent(
        List.unmodifiable(shelves),
        playlists,
        List.unmodifiable(results[0].take(quickPickCount)),
      );
      _builtFor = key;
      if (showNow) {
        _heldBack = null;
        _show(content);
      } else {
        _heldBack = content;
      }
      await _saveCache(content);
    } on Object catch (error) {
      debugPrint('Could not refresh Home: $error');
      _error = error;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _deleteCache() async {
    try {
      if (await cacheFile.exists()) await cacheFile.delete();
    } on FileSystemException catch (error) {
      debugPrint('Could not delete saved Home: $error');
    }
  }

  Future<List<Playlist>> _quickPlaylistsFrom(SubsonicClient client) async {
    try {
      return List.unmodifiable((await client.playlists()).take(quickPickCount));
    } on Object catch (error) {
      debugPrint('Could not load quick pick playlists: $error');
      return _quickPlaylists;
    }
  }

  Future<void> _saveCache(_HomeContent content) async {
    final temp = File('${cacheFile.path}.tmp');
    try {
      await cacheFile.parent.create(recursive: true);
      await temp.writeAsString(
        jsonEncode({
          'key': _builtFor,
          'shelves': [for (final shelf in content.shelves) shelf.toJson()],
          'quickPlaylists': [
            for (final playlist in content.playlists) playlist.toJson(),
          ],
          'quickSongs': [for (final song in content.songs) song.toJson()],
        }),
      );
      await temp.rename(cacheFile.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save Home: $error');
    }
  }

  @override
  void dispose() {
    history.removeListener(_onHistoryChanged);
    settings.removeListener(_onSettingsChanged);
    super.dispose();
  }
}

@immutable
class _HomeContent {
  const _HomeContent(this.shelves, this.playlists, this.songs);

  final List<HomeShelf> shelves;
  final List<Playlist> playlists;
  final List<Song> songs;
}
