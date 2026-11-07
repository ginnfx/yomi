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

  /// "Ask Yomi", the DeepSeek music assistant. Off until someone turns it on.
  bool get isAssistantOn => _prefs.getBool('assistantOn') ?? false;
  Future<void> setAssistantOn(bool value) =>
      _set(() => _prefs.setBool('assistantOn', value));

  /// Whether a new message from a friend shows a notification while Yomi isn't open.
  bool get areMessageNotificationsOn =>
      _prefs.getBool('messageNotifications') ?? true;
  Future<void> setMessageNotificationsOn(bool value) =>
      _set(() => _prefs.setBool('messageNotifications', value));

  /// Whether DeepSeek helps understand descriptions typed into Search ("calm songs
  /// for studying"). Off, Search only matches names in the library.
  bool get isAiSearchOn => _prefs.getBool('aiSearchOn') ?? true;
  Future<void> setAiSearchOn(bool value) =>
      _set(() => _prefs.setBool('aiSearchOn', value));

  /// Whether your top artists and moods go along with questions to the assistant.
  bool get sendsTasteToAssistant =>
      _prefs.getBool('assistantTaste') ?? true;
  Future<void> setSendsTasteToAssistant(bool value) =>
      _set(() => _prefs.setBool('assistantTaste', value));

  /// Whether Home suggests songs from outside the library once a week.
  bool get isDiscoverOn => _prefs.getBool('discoverOn') ?? true;
  Future<void> setDiscoverOn(bool value) =>
      _set(() => _prefs.setBool('discoverOn', value));

  Future<void> setShareListening(bool value) =>
      _set(() => _prefs.setBool('shareListening', value));

  /// Choices made for individual playlists, as a stable piece of text for comparing.
  String get playlistKeepChoices =>
      (_prefs
              .getKeys()
              .where((key) => key.startsWith('keepPlaylist.'))
              .map((key) => '$key=${_prefs.getBool(key)}')
              .toList()
            ..sort())
          .join(',');

  /// Forgets what belongs to the person signing out. Device preferences such as Wi-Fi only
  /// and the storage limit stay, because they're about this device.
  Future<void> clearPersonal() => _set(() async {
    final keys = _prefs.getKeys().where(
      (key) =>
          key.startsWith('keepPlaylist.') ||
          const {
            'shareListening',
            'aiSearchOn',
            'messageNotifications',
            'assistantTaste',
            'discoverOn',
            'recentSearches',
            'lessArtists',
            'lessSongs',
            'homeOrder',
            'homeHidden',
            'playlistOrder',
          }.contains(key),
    );
    for (final key in keys.toList()) {
      await _prefs.remove(key);
    }
    return true;
  });

  bool get wifiOnlyDownloads => _prefs.getBool('wifiOnlyDownloads') ?? true;

  /// Home screen sections, in the order shown. Unknown or missing ids are repaired.
  static const homeSectionIds = [
    'shuffle',
    'quick',
    'mixes',
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

  /// Whether Your Library shows a grid of covers instead of a list.
  bool get libraryIsGrid => _prefs.getBool('libraryIsGrid') ?? false;

  Future<void> setLibraryIsGrid(bool value) =>
      _set(() => _prefs.setBool('libraryIsGrid', value));

  /// How Your Library is ordered, by name; unknown names mean the custom order.
  String? get librarySort => _prefs.getString('librarySort');

  Future<void> setLibrarySort(String name) =>
      _set(() => _prefs.setString('librarySort', name));

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
