import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

const int _defaultCacheMb = 1024;
const List<int> cacheLimitChoicesMb = [256, 512, 1024, 2048, 4096];

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

  /// Save songs on repeat for offline play. Only ever fetches on Wi-Fi.
  bool get autoDownloadRepeats => _prefs.getBool('autoDownloadRepeats') ?? true;
  Future<void> setAutoDownloadRepeats(bool value) =>
      _set(() => _prefs.setBool('autoDownloadRepeats', value));

  bool get wifiOnlyDownloads => _prefs.getBool('wifiOnlyDownloads') ?? true;
  bool get cachePlayedSongs => _prefs.getBool('cachePlayedSongs') ?? true;
  Future<void> setCachePlayedSongs(bool value) =>
      _set(() => _prefs.setBool('cachePlayedSongs', value));
  bool get preloadNext => _prefs.getBool('preloadNext') ?? true;
  int get cacheLimitMb => _prefs.getInt('cacheLimitMb') ?? _defaultCacheMb;
  int get cacheLimitBytes => cacheLimitMb * 1024 * 1024;

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
  Future<void> setPreloadNext(bool value) =>
      _set(() => _prefs.setBool('preloadNext', value));
  Future<void> setCacheLimitMb(int value) =>
      _set(() => _prefs.setInt('cacheLimitMb', value));

  Future<void> _set(Future<bool> Function() write) async {
    await write();
    notifyListeners();
  }
}
