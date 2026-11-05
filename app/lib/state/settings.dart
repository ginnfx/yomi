import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

const int _defaultStorageGb = 5;
const int _maxRecentSearches = 8;
const List<int> storageLimitChoicesGb = [2, 5, 10, 20];

/// User preferences, saved on the device.
class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs);

  final SharedPreferences _prefs;

  static Future<SettingsController> load() async =>
      SettingsController(await SharedPreferences.getInstance());

  bool get syncListening => _prefs.getBool('syncListening') ?? true;
  Future<void> setSyncListening(bool value) =>
      _set(() => _prefs.setBool('syncListening', value));

  /// Whether the phone player shows big art instead of lyrics when a song has both.
  bool get prefersArtOverLyrics =>
      _prefs.getBool('prefersArtOverLyrics') ?? false;
  Future<void> setPrefersArtOverLyrics(bool value) =>
      _set(() => _prefs.setBool('prefersArtOverLyrics', value));

  /// How much Yomi may use by itself. Downloads you choose yourself don't count.
  int get storageLimitGb =>
      _prefs.getInt('storageLimitGb') ?? _defaultStorageGb;
  int get storageLimitBytes => storageLimitGb * 1024 * 1024 * 1024;
  Future<void> setStorageLimitGb(int value) =>
      _set(() => _prefs.setInt('storageLimitGb', value));

  /// Whether your playlists are saved for offline by themselves.
  bool get keepPlaylistsOffline =>
      _prefs.getBool('keepPlaylistsOffline') ?? true;
  Future<void> setKeepPlaylistsOffline(bool value) =>
      _set(() => _prefs.setBool('keepPlaylistsOffline', value));

  /// A choice made for one playlist, or null to follow the default.
  bool? playlistKeepChoice(String playlistId) =>
      _prefs.getBool('keepPlaylist.$playlistId');
  Future<void> setPlaylistKeepChoice(String playlistId, bool value) =>
      _set(() => _prefs.setBool('keepPlaylist.$playlistId', value));

  /// Artists and songs "show less like this" has ruled out of suggestions.
  Set<String> get lessArtists =>
      (_prefs.getStringList('lessArtists') ?? const <String>[]).toSet();
  Set<String> get lessSongs =>
      (_prefs.getStringList('lessSongs') ?? const <String>[]).toSet();
  Future<void> addLessArtist(String artist) =>
      _set(() => _prefs.setStringList('lessArtists', [...lessArtists, artist]));
  Future<void> addLessSong(String songId) =>
      _set(() => _prefs.setStringList('lessSongs', [...lessSongs, songId]));
  Future<void> clearLess() => _set(() async {
    await _prefs.remove('lessArtists');
    await _prefs.remove('lessSongs');
    return true;
  });

  /// What you searched for lately, newest first.
  List<String> get recentSearches =>
      _prefs.getStringList('recentSearches') ?? const [];
  Future<void> addRecentSearch(String text) => _set(
    () => _prefs.setStringList(
      'recentSearches',
      [
        text,
        ...recentSearches.where((other) => other != text),
      ].take(_maxRecentSearches).toList(),
    ),
  );
  Future<void> clearRecentSearches() =>
      _set(() => _prefs.remove('recentSearches'));

  /// Whether friends can see what you're playing, and you theirs. Off until you choose it.
  bool get shareListening => _prefs.getBool('shareListening') ?? false;
  Future<void> setShareListening(bool value) =>
      _set(() => _prefs.setBool('shareListening', value));

  bool get wifiOnlyDownloads => _prefs.getBool('wifiOnlyDownloads') ?? true;

  /// Home screen sections, in the order shown. Unknown or missing ids are repaired.
  static const homeSectionIds = [
    'shuffle',
    'quick',
    'jumpBack',
    'becauseYouPlayed',
    'topGenre',
    'rediscover',
    'timeOfDay',
    'recentlyAdded',
    'discover',
    'artistsYouLove',
    'newToYou',
    'mood',
    'pastYears',
  ];

  /// Set once the user arranges Home by hand; until then shelves rotate by themselves.
  bool get hasCustomHomeOrder => _prefs.containsKey('homeOrder');

  List<String> get homeOrder {
    final saved = (_prefs.getStringList('homeOrder') ?? const <String>[])
        .where(homeSectionIds.contains)
        .toList();
    return [...saved, ...homeSectionIds.where((id) => !saved.contains(id))];
  }

  Set<String> get hiddenHomeSections =>
      (_prefs.getStringList('homeHidden') ?? const <String>[]).toSet();

  List<String> get visibleHomeSections =>
      homeOrder.where((id) => !hiddenHomeSections.contains(id)).toList();

  Future<void> setHomeOrder(List<String> order) =>
      _set(() => _prefs.setStringList('homeOrder', order));

  Future<void> clearHomeOrder() => _set(() => _prefs.remove('homeOrder'));

  Future<void> setHomeHidden(Set<String> hidden) =>
      _set(() => _prefs.setStringList('homeHidden', hidden.toList()));

  /// Playlist ids in the user's own order (like dragging playlists around in Spotify).
  List<String> get playlistOrder =>
      _prefs.getStringList('playlistOrder') ?? const <String>[];

  Future<void> setPlaylistOrder(List<String> ids) =>
      _set(() => _prefs.setStringList('playlistOrder', ids));

  /// Playlists in the saved order; ones not seen before go on top, deleted ones are ignored.
  List<Playlist> orderPlaylists(List<Playlist> playlists) {
    final rank = {
      for (final entry in playlistOrder.indexed) entry.$2: entry.$1,
    };
    final known = playlists.where((p) => rank.containsKey(p.id)).toList()
      ..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
    return [...playlists.where((p) => !rank.containsKey(p.id)), ...known];
  }

  Future<void> setWifiOnlyDownloads(bool value) =>
      _set(() => _prefs.setBool('wifiOnlyDownloads', value));

  Future<void> _set(Future<bool> Function() write) async {
    await write();
    notifyListeners();
  }
}
