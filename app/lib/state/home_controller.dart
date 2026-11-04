import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/listening/play_history.dart';
import '../core/models.dart';
import '../core/recommendations.dart';
import '../core/subsonic_client.dart';
import 'settings.dart';

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
  String? _builtFor;
  bool _isLoading = false;
  Future<void>? _inFlight;
  int _generation = 0;
  Object? _error;

  bool get isLoading => _isLoading;
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

  Future<void> refreshIfDue() async {
    if (_builtFor == _currentKey && _shelves.isNotEmpty) return;
    await refresh();
  }

  /// Rebuilds Home now, or joins a rebuild already running. On failure the shelves
  /// already showing stay.
  Future<void> refresh() => _inFlight ??= _rebuild().whenComplete(() {
    _inFlight = null;
  });

  Future<void> _rebuild() async {
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
      if (generation != _generation)
        return; // Signed out while this was loading.
      final key = _currentKey;
      final order = settings.hasCustomHomeOrder
          ? [
              for (final id in settings.homeOrder)
                ?ShelfKind.values.asNameMap()[id],
            ]
          : null;
      _shelves = HomeBuilder(
        events: history.events,
        pool: {
          for (final song in [...history.songs, ...results[0], ...results[2]])
            song.id: song,
        }.values.toList(),
        recentlyAdded: results[1],
        starred: {for (final song in results[2]) song.id},
        now: _now(),
      ).build(keepOrder: order);
      _builtFor = key;
      await _saveCache();
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

  Future<void> _saveCache() async {
    final temp = File('${cacheFile.path}.tmp');
    try {
      await cacheFile.parent.create(recursive: true);
      await temp.writeAsString(
        jsonEncode({
          'key': _builtFor,
          'shelves': [for (final shelf in _shelves) shelf.toJson()],
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
