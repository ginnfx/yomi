import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/listening/play_history.dart';
import '../core/models.dart';
import '../core/recommendations.dart';
import '../core/taste.dart';
import '../core/subsonic_client.dart';
import 'settings.dart';

/// How many tiles sit at the top of Home.
const int quickPickCount = 6;
const int _libraryPoolSize = 200;
const int _recentCount = 16;
const int _recentAlbums = 20;

/// A new Home that's ready this soon after opening the app replaces the old one, before
/// you've started using it. Later ones wait, so nothing moves under your finger.
const Duration _justOpened = Duration(seconds: 5);

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
    this.libraryVersion,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _openedAt = _now();
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

  /// Changes when the library does, such as after new songs are added.
  final String? Function()? libraryVersion;
  final DateTime Function() _now;
  SubsonicClient? _client;
  List<HomeShelf> _shelves = const [];
  TasteProfile _taste = TasteProfile.empty;
  List<Playlist> _quickPlaylists = const [];
  List<Song> _quickSongs = const [];
  _HomeContent? _heldBack;
  Map<String, ShownRecord> _shown = const {};
  String? _builtForDay;
  DateTime? _builtAt;
  String? _builtFromLibrary;
  late DateTime _openedAt;
  bool _isLoading = false;
  StreamSubscription<String>? _playlistUpdates;
  Future<void>? _inFlight;
  bool _isCheckDue = false;
  int _rebuilds = 0;
  int _generation = 0;
  Object? _error;

  bool get isLoading => _isLoading;

  /// What this person likes, from the last time Home was worked out.
  TasteProfile get taste => _taste;

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

  /// Home changes on a new day, after enough new plays, or when the library changes.
  bool get _isDue {
    if (_shelves.isEmpty || _builtForDay != homeDayKey(_now())) return true;
    final version = libraryVersion?.call();
    if (version != null && version != _builtFromLibrary) return true;
    final since = _builtAt;
    if (since == null) return true;
    final newPlays = history.events.where((e) => e.at.isAfter(since)).length;
    return newPlays >= kPlaysPerRefresh;
  }

  Future<void> loadCache() async {
    try {
      if (!await cacheFile.exists()) return;
      final json = jsonDecode(await cacheFile.readAsString());
      if (json is! Map<String, dynamic>) return;
      _builtForDay = json['day'] as String?;
      _builtAt = DateTime.tryParse(json['builtAt'] as String? ?? '');
      _builtFromLibrary = json['library'] as String?;
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
            in ((json['shownAt'] as Map<String, dynamic>?) ?? const {}).entries)
          entry.key: ShownRecord.fromJson(entry.value as Map<String, dynamic>),
      };
      notifyListeners();
    } on Object catch (error) {
      // Home simply rebuilds; a damaged cache costs nothing else.
      debugPrint('Ignoring saved Home: $error');
      _builtForDay = null;
      _shelves = const [];
    }
  }

  void attach(SubsonicClient? client) {
    final isNewClient = !identical(client, _client);
    _client = client;
    if (isNewClient) {
      unawaited(_playlistUpdates?.cancel());
      _playlistUpdates = client?.catalogUpdates.listen((endpoint) {
        if (endpoint == 'getPlaylists') _updateQuickPlaylists();
      });
    }
    if (client == null) {
      _shelves = const [];
      _taste = TasteProfile.empty;
      _quickPlaylists = const [];
      _quickSongs = const [];
      _heldBack = null;
      _builtForDay = null;
      _builtAt = null;
      _builtFromLibrary = null;
      _shown = const {};
      _generation++;
      // The next person to sign in on this device shouldn't see this Home.
      unawaited(_deleteCache());
      notifyListeners();
    } else if (isNewClient) {
      unawaited(refreshIfDue());
    }
  }

  /// Keeps the playlists at the top in place, with their latest names and covers, and
  /// drops any since deleted. Their order only changes with the rest of Home.
  void _updateQuickPlaylists() {
    final cached = _client?.cachedPlaylists;
    if (cached == null)
      return; // Nothing known, which isn't the same as none left.
    final latest = {for (final playlist in cached) playlist.id: playlist};
    List<Playlist> current(List<Playlist> playlists) => List.unmodifiable([
      for (final playlist in playlists) ?latest[playlist.id],
    ]);
    _quickPlaylists = current(_quickPlaylists);
    final held = _heldBack;
    if (held != null) {
      _heldBack = _HomeContent(
        held.shelves,
        current(held.playlists),
        held.songs,
      );
    }
    // What's saved is what the next launch shows, so it needs the change too.
    unawaited(
      _saveCache(
        _heldBack ?? _HomeContent(_shelves, _quickPlaylists, _quickSongs),
      ),
    );
    notifyListeners();
  }

  void _onHistoryChanged() => unawaited(refreshIfDue());

  void _onSettingsChanged() => notifyListeners();

  /// Prepares a new Home if one is due. If Home is already showing, the new version is
  /// saved but held back until [applyHeldBack], so nothing changes under your finger.
  Future<void> refreshIfDue() async {
    final running = _inFlight;
    if (running != null) {
      _isCheckDue = true; // What's being built may already be out of date.
      await running;
      return;
    }
    if (!_isDue) return;
    await _startRebuild(showNow: _shelves.isEmpty);
  }

  /// Marks the app as just opened, so a new Home can appear before you start using it.
  void appOpened() => _openedAt = _now();

  /// Rebuilds Home now, or joins a rebuild already running, because you asked for it. On
  /// failure the shelves already showing stay.
  Future<void> refresh() async {
    await _startRebuild(showNow: true);
    applyHeldBack();
  }

  Future<void> _startRebuild({required bool showNow}) =>
      _inFlight ??= _rebuild(showNow: showNow).whenComplete(() {
        _inFlight = null;
        if (_isCheckDue) {
          _isCheckDue = false;
          unawaited(refreshIfDue());
        }
      });

  /// Shows a version of Home that was prepared in the background. Called when the app
  /// comes back after a while away.
  void applyHeldBack() {
    final held = _heldBack;
    if (held == null) return;
    _heldBack = null;
    // Out of date already, and a newer one is on its way. Showing this would make Home
    // change twice in a row.
    if (_isDue) return;
    _show(held);
    unawaited(_saveCache(held));
    notifyListeners();
  }

  void _show(_HomeContent content) {
    // Counted when it's really on screen, as a song shouldn't fade for shelves never seen.
    _shown = _countShown(content);
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
      // Read when it starts, so changes during the rebuild trigger another one.
      final version = library.isEmpty ? null : libraryVersion?.call();
      final newest = newestSongs(library);
      final results = await Future.wait<List<Song>>([
        library.isNotEmpty
            ? Future.value(library)
            : client.randomSongs(size: _libraryPoolSize),
        newest.isNotEmpty
            ? Future.value(newest)
            : library.isNotEmpty
            ? _recentFromCatalog(client, library)
            : client.recentSongs(count: _recentCount),
        client.starredSongs(),
      ]);
      final playlists = await _quickPlaylistsFrom(client);
      if (generation != _generation)
        return; // Signed out while this was loading.
      final builtAt = _now();
      // A new seed each time, so pulling to refresh really does give you something new.
      final seed = builtAt.microsecondsSinceEpoch + ++_rebuilds;
      final order = settings.hasCustomHomeOrder
          ? [
              for (final id in settings.homeOrder)
                ?ShelfKind.values.asNameMap()[id],
            ]
          : null;
      final builder = HomeBuilder(
        events: [...?otherDevicePlays?.call(), ...history.events],
        pool: {
          for (final song in [...history.songs, ...results[0], ...results[2]])
            song.id: song,
        }.values.toList(),
        recentlyAdded: results[1],
        starred: {for (final song in results[2]) song.id},
        now: _now(),
        shown: _wornOut(builtAt),
        recentlyShown: _onScreen(),
        seed: seed,
        lessArtists: settings.lessArtists,
        lessSongs: settings.lessSongs,
        moodsById: moodsFor?.call(results[0]) ?? const {},
        similarArtists: similarArtists?.call() ?? const {},
        importedTaste: importedTaste?.call() ?? const {},
        pastFavourites: pastFavouritesFor?.call(results[0]) ?? const {},
      );
      final shelves = builder.build(keepOrder: order);
      _taste = builder.taste();
      final content = _HomeContent(
        List.unmodifiable(shelves),
        playlists,
        _quickSongsFrom(results[0], seed),
      );
      _builtForDay = homeDayKey(builtAt);
      _builtAt = builtAt;
      _builtFromLibrary = version;
      if (showNow || _now().difference(_openedAt) < _justOpened) {
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

  /// A few songs for the top of Home, which change with Home rather than on every open,
  /// and differ from the last few when there are enough to choose from.
  List<Song> _quickSongsFrom(List<Song> pool, int seed) {
    final previous = {for (final song in _quickSongs) song.id};
    final allowed = [
      for (final song in pool)
        if (!settings.lessSongs.contains(song.id) &&
            !settings.lessArtists.contains(song.artist))
          song,
    ]..shuffle(Random(seed));
    return List.unmodifiable(
      [
        ...allowed.where((song) => !previous.contains(song.id)),
        ...allowed.where((song) => previous.contains(song.id)),
      ].take(quickPickCount),
    );
  }

  /// Everything on Home right now that was suggested, rather than simply played last.
  Set<String> _onScreen() => {
    for (final shelf in _shelves)
      if (shelf.kind != ShelfKind.jumpBack)
        for (final song in shelf.songs) song.id,
    for (final song in _quickSongs) song.id,
  };

  /// How many times each song has been shown, counting only what's still resting.
  Map<String, int> _wornOut(DateTime now) => {
    for (final entry in _shown.entries)
      if (now.difference(entry.value.lastShown) < kShownRest)
        entry.key: entry.value.times,
  };

  /// Adds up what's on screen. A song is forgiven once it's been played since it was last
  /// shown, or after a long enough rest, so it only fades while it's being ignored.
  Map<String, ShownRecord> _countShown(_HomeContent content) {
    final now = _now();
    final lastPlayed = <String, DateTime>{};
    for (final event in history.events) {
      if (event.kind != PlayKind.completed) continue;
      final latest = lastPlayed[event.songId];
      if (latest == null || event.at.isAfter(latest)) {
        lastPlayed[event.songId] = event.at;
      }
    }
    final kept = <String, ShownRecord>{
      for (final entry in _shown.entries)
        if (now.difference(entry.value.lastShown) < kShownRest &&
            !(lastPlayed[entry.key]?.isAfter(entry.value.lastShown) ?? false))
          entry.key: entry.value,
    };
    return {
      ...kept,
      for (final shelf in content.shelves)
        if (shelf.kind != ShelfKind.jumpBack)
          for (final song in shelf.songs)
            song.id: ShownRecord((kept[song.id]?.times ?? 0) + 1, now),
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
          'day': _builtForDay,
          'builtAt': _builtAt?.toIso8601String(),
          'library': _builtFromLibrary,
          'shelves': [for (final shelf in content.shelves) shelf.toJson()],
          'quickPlaylists': [
            for (final playlist in content.playlists) playlist.toJson(),
          ],
          'quickSongs': [for (final song in content.songs) song.toJson()],
          'shownAt': {
            for (final entry in _shown.entries) entry.key: entry.value.toJson(),
          },
        }),
      );
      await temp.rename(cacheFile.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not save Home: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_playlistUpdates?.cancel());
    history.removeListener(_onHistoryChanged);
    settings.removeListener(_onSettingsChanged);
    super.dispose();
  }
}

/// How often a song has been offered on Home, and when it last was.
@immutable
class ShownRecord {
  const ShownRecord(this.times, this.lastShown);

  factory ShownRecord.fromJson(Map<String, dynamic> json) => ShownRecord(
    (json['times'] as num).toInt(),
    DateTime.fromMillisecondsSinceEpoch((json['at'] as num).toInt()),
  );

  final int times;
  final DateTime lastShown;

  Map<String, Object?> toJson() => {
    'times': times,
    'at': lastShown.millisecondsSinceEpoch,
  };
}

@immutable
class _HomeContent {
  const _HomeContent(this.shelves, this.playlists, this.songs);

  final List<HomeShelf> shelves;
  final List<Playlist> playlists;
  final List<Song> songs;
}
