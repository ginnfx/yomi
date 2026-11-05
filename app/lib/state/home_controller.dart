import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
const int _recentAlbums = 20;

/// Keeps Home's shelves. They're saved to disk so Home opens instantly and offline, and
/// only rebuilt when the rotation key changes: a new day, or enough new plays.
class HomeController extends ChangeNotifier {
  HomeController({
    required this.history,
    required this.settings,
    required this.cacheFile,
    this.catalogSongs,
    this.moodsFor,
    this.similarArtists,
    this.otherDevicePlays,
    this.importedTaste,
    this.pastFavouritesFor,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    history.addListener(_onHistoryChanged);
    settings.addListener(_onSettingsChanged);
  }

  final PlayHistory history;
  final SettingsController settings;
  final File cacheFile;

  /// The whole library saved on this device, when it's available.
  final List<Song> Function()? catalogSongs;

  /// AI labels for songs and artists, when there are any.
  final Map<String, List<String>> Function(List<Song> songs)? moodsFor;
  final Map<String, List<String>> Function()? similarArtists;

  /// Plays from your other devices, which is what lets a new one start personal.
  final List<PlayEvent> Function()? otherDevicePlays;

  /// What's known from a Spotify export.
  final Map<String, double> Function()? importedTaste;
  final Map<int, List<Song>> Function(List<Song> songs)? pastFavouritesFor;
  final DateTime Function() _now;
  SubsonicClient? _client;
  List<HomeShelf> _shelves = const [];
  List<Playlist> _quickPlaylists = const [];
  List<Song> _quickSongs = const [];
  _HomeContent? _heldBack;
  Map<String, int> _shown = const {};
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
      _shown = {
        for (final entry
            in ((json['shown'] as Map<String, dynamic>?) ?? const {}).entries)
          entry.key: (entry.value as num).toInt(),
      };
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
      final library = catalogSongs?.call() ?? const <Song>[];
      final results = await Future.wait<List<Song>>([
        library.isNotEmpty
            ? Future.value(library)
            : client.randomSongs(size: _libraryPoolSize),
        library.isNotEmpty
            ? _recentFromCatalog(client, library)
            : client.recentSongs(count: _recentCount),
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
        events: [...?otherDevicePlays?.call(), ...history.events],
        pool: {
          for (final song in [...history.songs, ...results[0], ...results[2]])
            song.id: song,
        }.values.toList(),
        recentlyAdded: results[1],
        starred: {for (final song in results[2]) song.id},
        now: _now(),
        shown: _shown,
        lessArtists: settings.lessArtists,
        lessSongs: settings.lessSongs,
        moodsById: moodsFor?.call(results[0]) ?? const {},
        similarArtists: similarArtists?.call() ?? const {},
        importedTaste: importedTaste?.call() ?? const {},
        pastFavourites: pastFavouritesFor?.call(results[0]) ?? const {},
      ).build(keepOrder: order);
      _shown = _countShown(shelves);
      final content = _HomeContent(
        List.unmodifiable(shelves),
        playlists,
        _quickSongsFrom(results[0]),
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

  /// Newest albums first, using the saved library so it needn't ask for each album.
  Future<List<Song>> _recentFromCatalog(
    SubsonicClient client,
    List<Song> library,
  ) async {
    final albums = await client.albums('newest', size: _recentAlbums);
    final byAlbum = <String, List<Song>>{};
    for (final song in library) {
      final id = song.albumId;
      if (id != null) (byAlbum[id] ??= []).add(song);
    }
    return [for (final album in albums) ...?byAlbum[album.id]];
  }

  /// A few songs for the top of Home, which change with Home rather than on every open.
  List<Song> _quickSongsFrom(List<Song> pool) {
    final sample = [...pool]..shuffle(Random(_currentKey.hashCode));
    return List.unmodifiable(sample.take(quickPickCount));
  }

  /// Adds up what's on screen, and forgets anything played since, so a song only fades
  /// from Home when it keeps being offered without being chosen.
  Map<String, int> _countShown(List<HomeShelf> shelves) {
    final playedSince = {
      for (final event in history.events)
        if (event.kind == PlayKind.completed) event.songId,
    };
    return {
      for (final entry in _shown.entries)
        if (!playedSince.contains(entry.key)) entry.key: entry.value,
      for (final shelf in shelves)
        for (final song in shelf.songs)
          if (!playedSince.contains(song.id))
            song.id: (_shown[song.id] ?? 0) + 1,
    };
  }

  /// "Show less like this": rules out the song, and its artist if [wholeArtist].
  Future<void> showLess(Song song, {required bool wholeArtist}) async {
    await (wholeArtist
        ? settings.addLessArtist(song.artist)
        : settings.addLessSong(song.id));
    _shelves = List.unmodifiable(
      _shelves
          .map(
            (shelf) => HomeShelf(shelf.kind, shelf.title, [
              for (final other in shelf.songs)
                if (other.id != song.id &&
                    !(wholeArtist && other.artist == song.artist))
                  other,
            ]),
          )
          .where((shelf) => shelf.songs.isNotEmpty),
    );
    notifyListeners();
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
          'shown': _shown,
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
