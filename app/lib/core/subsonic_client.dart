import 'dart:async';

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'catalog_cache.dart';
import 'lyrics.dart';
import 'models.dart';
import 'offline/outbox.dart';
import 'saved_play_queue.dart';

const String _apiVersion = '1.16.1';
const String _clientName = 'Yomi';
const int _saltLength = 10;
const Duration _requestTimeout = Duration(seconds: 20);
const Duration _scanTimeout = Duration(seconds: 8);
const Duration _catalogPageTimeout = Duration(seconds: 60);

enum ErrorKind {
  unreachable,
  badCredentials,
  notNavidrome,
  server,
  readOnly,
  other,
}

class SubsonicException implements Exception {
  const SubsonicException(
    this.message, {
    this.code,
    this.kind = ErrorKind.other,
  });

  final String message;
  final int? code;
  final ErrorKind kind;

  bool get isBadCredentials => code == 40 || kind == ErrorKind.badCredentials;

  @override
  String toString() => message;
}

@immutable
class ScanStatus {
  const ScanStatus({required this.isScanning, this.lastScan, this.count});

  final bool isScanning;

  /// When the last scan finished; changes whenever the library may have changed.
  final String? lastScan;
  final int? count;
}

/// Thin client for the Subsonic/OpenSubsonic API that Navidrome serves.
class SubsonicClient {
  SubsonicClient({
    required String baseUrl,
    required this.username,
    required String password,
    http.Client? httpClient,
    CatalogCache? cache,
    Outbox? outbox,
    String Function()? saltGenerator,
    bool Function()? isReadOnly,
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
       _cache = cache,
       _outbox = outbox,
       _password = password,
       _http = httpClient ?? http.Client(),
       _newSalt = saltGenerator ?? _randomSalt,
       _isReadOnly = isReadOnly ?? _alwaysWritable;

  final String baseUrl;
  final String username;
  final String _password;
  final CatalogCache? _cache;
  final Outbox? _outbox;
  final http.Client _http;
  final String Function() _newSalt;
  final bool Function() _isReadOnly;

  static bool _alwaysWritable() => false;

  /// True on the backup server, whose database is replaced from the main one, so
  /// anything written there would be lost.
  bool get isReadOnly => _isReadOnly();

  void _requireWritable() {
    if (isReadOnly) {
      throw const SubsonicException(
        "You're on the backup server, so changes can't be saved right now.",
        kind: ErrorKind.readOnly,
      );
    }
  }

  /// Sends a change to the server, then updates only the saved data it affects.
  /// [clears] lists the endpoints whose saved data is now wrong. [refreshesAll] keeps
  /// everything on screen but re-checks it on the next read, for changes such as a star
  /// that appear inside many saved responses.
  Future<Map<String, dynamic>> _write(
    String endpoint, [
    Map<String, Object?> params = const {},
    Set<String> clears = const {},
    bool refreshesAll = false,
  ]) async {
    _requireWritable();
    final Map<String, dynamic> result;
    try {
      result = await _get(endpoint, params);
    } on SubsonicException catch (error) {
      final outbox = _outbox;
      if (error.kind != ErrorKind.unreachable ||
          outbox == null ||
          !_waitableEndpoints.contains(endpoint)) {
        rethrow;
      }
      await outbox.add(OutboxItem(endpoint, params));
      return const {};
    }
    final cache = _cache;
    if (cache != null) {
      if (clears.isNotEmpty) cache.remove(clears);
      if (refreshesAll) cache.markAllStale();
    }
    return result;
  }

  late final String _sessionSalt = _newSalt();

  static String _randomSalt() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(
      _saltLength,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  /// Token auth: the password never travels in the URL.
  ///
  /// [stable] reuses one salt for the whole session so image URLs stay identical
  /// between rebuilds and the image cache works.
  Map<String, String> authParams({bool stable = false}) {
    final salt = stable ? _sessionSalt : _newSalt();
    final token = md5.convert(utf8.encode('$_password$salt')).toString();
    return {
      'u': username,
      't': token,
      's': salt,
      'v': _apiVersion,
      'c': _clientName,
      'f': 'json',
    };
  }

  Uri _uri(
    String endpoint, [
    Map<String, Object?> params = const {},
    bool stable = false,
  ]) {
    final query = <String, Object>{...authParams(stable: stable)};
    params.forEach((key, value) {
      if (value == null) return;
      query[key] = value is Iterable
          ? value.map((e) => e.toString()).toList()
          : value.toString();
    });
    final base = Uri.parse(baseUrl);
    return base.replace(
      path: '${base.path}/rest/$endpoint',
      queryParameters: query,
    );
  }

  static const Set<String> _playlistEndpoints = {'getPlaylists', 'getPlaylist'};

  /// Changes that can safely wait until the server is back. A scan can't: it's only
  /// useful now.
  static const Set<String> _waitableEndpoints = {
    'star',
    'unstar',
    'createPlaylist',
    'updatePlaylist',
    'deletePlaylist',
  };

  /// A saved action that isn't a single server call: removing a song once the server's
  /// current list can be checked, so it can't remove the wrong one.
  static const String _removeSongAction = 'removeSongFromPlaylist';

  /// Sends changes made while the server couldn't be reached, in the order they were
  /// made. Stops if it drops again. A change the server refuses can never succeed, so it's
  /// dropped rather than blocking everything after it.
  Future<void> flushOutbox() async {
    final outbox = _outbox;
    if (outbox == null) return;
    await outbox.load();
    while (outbox.items.isNotEmpty) {
      final item = outbox.items.first;
      try {
        await _send(item);
      } on SubsonicException catch (error) {
        if (error.kind == ErrorKind.unreachable) return;
        debugPrint('Dropping a saved change the server refused: $error');
      }
      await outbox.removeFirst();
    }
  }

  Future<void> _send(OutboxItem item) async {
    if (item.endpoint == _removeSongAction) {
      await _removeSong(
        item.params['playlistId'] as String,
        item.params['songId'] as String,
        (item.params['index'] as num).toInt(),
      );
      return;
    }
    await _get(item.endpoint, item.params);
    _cache?.markAllStale();
  }

  final Map<String, Future<Map<String, dynamic>>> _pendingReads = {};
  static const _cachedEndpoints = {
    'getSong',
    'getAlbumList2',
    'getAlbum',
    'getArtists',
    'getArtist',
    'getGenres',
    'getSongsByGenre',
    'getPlaylists',
    'getPlaylist',
    'getStarred2',
    'search3',
  };

  Future<Map<String, dynamic>> _get(
    String endpoint, [
    Map<String, Object?> params = const {},
    Duration? timeout,
    bool post = false,
  ]) async {
    final cache = _cache;
    if (cache == null || post || !_cachedEndpoints.contains(endpoint)) {
      return _fetch(endpoint, params, timeout, post);
    }
    await cache.load();
    Future<Map<String, dynamic>> refresh() =>
        _pendingReads.putIfAbsent(jsonEncode([endpoint, params]), () async {
          try {
            final result = await _fetch(endpoint, params, timeout, post);
            cache.put(endpoint, params, result);
            return result;
          } finally {
            _pendingReads.remove(jsonEncode([endpoint, params]));
          }
        });
    final saved = cache.peek(endpoint, params);
    if (saved == null) return refresh();
    if (!saved.isFresh) {
      unawaited(refresh().then<void>((_) {}, onError: (Object _) {}));
    }
    return saved.data;
  }

  /// Removes [song], checking the server's current list first, because the list on screen
  /// may be out of date and a wrong position would remove a different song.
  Future<void> removeSongFromPlaylist(
    String playlistId,
    Song song,
    int shownIndex,
  ) async {
    try {
      await _removeSong(playlistId, song.id, shownIndex);
    } on SubsonicException catch (error) {
      final outbox = _outbox;
      if (error.kind != ErrorKind.unreachable || outbox == null) rethrow;
      await outbox.add(
        OutboxItem(_removeSongAction, {
          'playlistId': playlistId,
          'songId': song.id,
          'index': shownIndex,
        }),
      );
    }
  }

  Future<void> _removeSong(String playlistId, String songId, int index) async {
    final current = await freshPlaylistSongs(playlistId);
    final isStillThere = index < current.length && current[index].id == songId;
    final at = isStillThere
        ? index
        : current.indexWhere((entry) => entry.id == songId);
    if (at >= 0) await removeFromPlaylist(playlistId, [at]);
  }

  /// A saved response, available straight away, or null if there isn't one yet.
  Map<String, dynamic>? _peek(
    String endpoint, [
    Map<String, Object?> params = const {},
  ]) => _cache?.peek(endpoint, params)?.data;

  /// Fires when saved data for an endpoint changes, so screens can show the new version.
  Stream<String> get catalogUpdates =>
      _cache?.updates ?? const Stream<String>.empty();

  Future<Map<String, dynamic>> _fetch(
    String endpoint, [
    Map<String, Object?> params = const {},
    Duration? timeout,
    bool post = false,
  ]) async {
    final http.Response response;
    try {
      final uri = _uri(endpoint, params);
      final request = post
          ? _http.post(
              uri.replace(query: ''),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: uri.query,
            )
          : _http.get(uri);
      response = await request.timeout(timeout ?? _requestTimeout);
    } on Exception catch (error) {
      throw SubsonicException(
        'Cannot reach the server. ($error)',
        kind: ErrorKind.unreachable,
      );
    }
    if (response.statusCode != 200) {
      throw SubsonicException(
        'Server answered ${response.statusCode}.',
        kind: response.statusCode >= 500 ? ErrorKind.server : ErrorKind.other,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const SubsonicException(
        'That address is not a Navidrome server.',
        kind: ErrorKind.notNavidrome,
      );
    }
    final body = decoded is Map<String, dynamic>
        ? decoded['subsonic-response']
        : null;
    if (body is! Map<String, dynamic>) {
      throw const SubsonicException(
        'That address is not a Navidrome server.',
        kind: ErrorKind.notNavidrome,
      );
    }
    if (body['status'] != 'ok') {
      final error = body['error'];
      final code = error is Map<String, dynamic>
          ? (error['code'] as num?)?.toInt()
          : null;
      final message = error is Map<String, dynamic>
          ? error['message'] as String?
          : null;
      throw SubsonicException(
        code == 40
            ? 'Wrong username or password.'
            : (message ?? 'Request failed.'),
        code: code,
        kind: code == 40 ? ErrorKind.badCredentials : ErrorKind.other,
      );
    }
    return body;
  }

  /// [timeout] lets the home-network check fail fast instead of hanging for 20 seconds.
  Future<void> ping({Duration? timeout}) => _get('ping', const {}, timeout);

  Future<List<Album>> albums(
    String type, {
    int size = 20,
    int offset = 0,
  }) async {
    final body = await _get('getAlbumList2', {
      'type': type,
      'size': size,
      'offset': offset,
    });
    return jsonList(
      body['albumList2'] as Map<String, dynamic>?,
      'album',
    ).map(Album.fromJson).toList(growable: false);
  }

  Future<Song> song(String songId) async {
    final body = await _get('getSong', {'id': songId});
    final json = body['song'];
    if (json is! Map<String, dynamic>) {
      throw const SubsonicException('That song is not on this server.');
    }
    return Song.fromJson(json);
  }

  Future<List<Genre>> genres() async {
    final body = await _get('getGenres');
    return jsonList(
      body['genres'] as Map<String, dynamic>?,
      'genre',
    ).map(Genre.fromJson).toList(growable: false);
  }

  Future<List<Song>> songsByGenre(
    String genre, {
    int offset = 0,
    int count = 100,
  }) async {
    final body = await _get('getSongsByGenre', {
      'genre': genre,
      'offset': offset,
      'count': count,
    });
    return jsonList(
      body['songsByGenre'] as Map<String, dynamic>?,
      'song',
    ).map(Song.fromJson).toList(growable: false);
  }

  Future<List<Song>> randomSongs({int size = 20}) async {
    final body = await _get('getRandomSongs', {'size': size});
    return jsonList(
      body['randomSongs'] as Map<String, dynamic>?,
      'song',
    ).map(Song.fromJson).toList(growable: false);
  }

  Future<SearchResults> search(
    String query, {
    int count = 40,
    int offset = 0,
  }) async {
    if (query.trim().isEmpty) return const SearchResults();
    final body = await _get('search3', {
      'query': query.trim(),
      'songCount': count,
      'songOffset': offset,
      'albumCount': 0,
      'artistCount': offset == 0 ? 10 : 0,
    });
    final result = body['searchResult3'] as Map<String, dynamic>?;
    return SearchResults(
      songs: jsonList(
        result,
        'song',
      ).map(Song.fromJson).toList(growable: false),
      albums: jsonList(
        result,
        'album',
      ).map(Album.fromJson).toList(growable: false),
      artists: jsonList(
        result,
        'artist',
      ).map(Artist.fromJson).toList(growable: false),
    );
  }

  /// Every song in the library, one page at a time (alphabetical).
  Future<List<Song>> songs({int offset = 0, int count = 100}) async {
    final body = await _get('search3', {
      'query': '',
      'songCount': count,
      'songOffset': offset,
      'albumCount': 0,
      'artistCount': 0,
    });
    return jsonList(
      body['searchResult3'] as Map<String, dynamic>?,
      'song',
    ).map(Song.fromJson).toList(growable: false);
  }

  /// All songs by an artist (the server groups them into albums; the app does not show albums).
  Future<List<Song>> artistSongs(String artistId) async {
    final albums = await artistAlbums(artistId);
    final lists = await Future.wait(albums.map((a) => albumSongs(a.id)));
    return [for (final list in lists) ...list];
  }

  /// The newest songs, newest first. Albums are fetched one at a time and only
  /// until there are enough songs, so one Home load can't flood a small server.
  Future<List<Song>> recentSongs({int count = 16}) async {
    final albums = await this.albums('newest', size: count);
    final found = <Song>[];
    for (final album in albums) {
      if (found.length >= count) break;
      found.addAll(await albumSongs(album.id));
    }
    return List.unmodifiable(found.take(count));
  }

  /// Tells the server what is playing. With [submission] the play counts toward
  /// history at [time]; without it the song only shows as "now playing".
  Future<void> scrobble(
    String songId, {
    bool submission = true,
    DateTime? time,
  }) => _write('scrobble', {
    'id': songId,
    'submission': '$submission',
    if (time != null) 'time': '${time.millisecondsSinceEpoch}',
  });

  Future<List<Artist>> artists() async =>
      _parseArtists(await _get('getArtists'));

  /// The saved artists, without waiting, or null if there are none yet.
  List<Artist>? get cachedArtists {
    final body = _peek('getArtists');
    return body == null ? null : _parseArtists(body);
  }

  static List<Artist> _parseArtists(Map<String, dynamic> body) => [
    for (final index in jsonList(
      body['artists'] as Map<String, dynamic>?,
      'index',
    ))
      ...jsonList(index, 'artist').map(Artist.fromJson),
  ];

  Future<List<Album>> artistAlbums(String artistId) async {
    final body = await _get('getArtist', {'id': artistId});
    return jsonList(
      body['artist'] as Map<String, dynamic>?,
      'album',
    ).map(Album.fromJson).toList(growable: false);
  }

  Future<List<Song>> albumSongs(String albumId) async =>
      _parseAlbumSongs(await _get('getAlbum', {'id': albumId}));

  /// The saved songs of an album, without waiting, or null if there are none yet.
  List<Song>? cachedAlbumSongs(String albumId) {
    final body = _peek('getAlbum', {'id': albumId});
    return body == null ? null : _parseAlbumSongs(body);
  }

  static List<Song> _parseAlbumSongs(Map<String, dynamic> body) => jsonList(
    body['album'] as Map<String, dynamic>?,
    'song',
  ).map(Song.fromJson).toList(growable: false);

  Future<List<Playlist>> playlists() async =>
      _parsePlaylists(await _get('getPlaylists'));

  /// Asks the server again, ignoring saved data. Screens hear through [catalogUpdates].
  Future<void> refreshPlaylists() async {
    _cache?.remove(_playlistEndpoints);
    await playlists();
  }

  Future<void> refreshArtists() async {
    _cache?.remove(const {'getArtists'});
    await artists();
  }

  /// The saved playlists, without waiting, or null if there are none yet.
  List<Playlist>? get cachedPlaylists {
    final body = _peek('getPlaylists');
    return body == null ? null : _parsePlaylists(body);
  }

  static List<Playlist> _parsePlaylists(Map<String, dynamic> body) => jsonList(
    body['playlists'] as Map<String, dynamic>?,
    'playlist',
  ).map(Playlist.fromJson).toList(growable: false);

  Future<List<Song>> playlistSongs(String playlistId) async =>
      _parsePlaylistSongs(await _get('getPlaylist', {'id': playlistId}));

  /// The saved songs of a playlist, without waiting, or null if there are none yet.
  List<Song>? cachedPlaylistSongs(String playlistId) {
    final body = _peek('getPlaylist', {'id': playlistId});
    return body == null ? null : _parsePlaylistSongs(body);
  }

  static List<Song> _parsePlaylistSongs(Map<String, dynamic> body) => jsonList(
    body['playlist'] as Map<String, dynamic>?,
    'entry',
  ).map(Song.fromJson).toList(growable: false);

  Future<void> createPlaylist(String name, {List<String> songIds = const []}) =>
      _write('createPlaylist', {
        'name': name,
        'songId': songIds,
      }, _playlistEndpoints);

  Future<void> addToPlaylist(String playlistId, List<String> songIds) => _write(
    'updatePlaylist',
    {'playlistId': playlistId, 'songIdToAdd': songIds},
    _playlistEndpoints,
  );

  Future<void> removeFromPlaylist(String playlistId, List<int> indexes) =>
      _write('updatePlaylist', {
        'playlistId': playlistId,
        'songIndexToRemove': indexes,
      }, _playlistEndpoints);

  Future<void> renamePlaylist(String playlistId, String name) => _write(
    'updatePlaylist',
    {'playlistId': playlistId, 'name': name},
    _playlistEndpoints,
  );

  Future<void> deletePlaylist(String playlistId) =>
      _write('deletePlaylist', {'id': playlistId}, _playlistEndpoints);

  Future<List<Song>> starredSongs() async {
    final body = await _get('getStarred2');
    return jsonList(
      body['starred2'] as Map<String, dynamic>?,
      'song',
    ).map(Song.fromJson).toList(growable: false);
  }

  Future<void> star(String songId) =>
      _write('star', {'id': songId}, const {}, true);

  Future<void> unstar(String songId) =>
      _write('unstar', {'id': songId}, const {}, true);

  /// OpenSubsonic lyrics stored with the song; null when there are none.
  Future<Lyrics?> lyricsFor(String songId) async {
    final body = await _get('getLyricsBySongId', {'id': songId});
    final lists = jsonList(
      body['lyricsList'] as Map<String, dynamic>?,
      'structuredLyrics',
    );
    if (lists.isEmpty) return null;
    final chosen = lists.firstWhere(
      (l) => l['synced'] == true,
      orElse: () => lists.first,
    );
    final lines = jsonList(chosen, 'line');
    final isSynced = chosen['synced'] == true;
    if (lines.isEmpty) return null;
    final offsetMs = (chosen['offset'] as num?)?.toInt() ?? 0;
    return Lyrics([
      for (final l in lines)
        LyricLine(
          isSynced
              ? Lyrics.applyOffset(
                  Duration(milliseconds: (l['start'] as num?)?.toInt() ?? 0),
                  offsetMs,
                )
              : null,
          (l['value'] as String?)?.trim() ?? '',
        ),
    ], isSynced: isSynced);
  }

  Future<SavedPlayQueue?> savedPlayQueue() async {
    final body = await _get('getPlayQueue');
    return SavedPlayQueue.fromJson(body['playQueue'] as Map<String, dynamic>?);
  }

  Future<void> savePlayQueue({
    required List<Song> songs,
    required int index,
    required Duration position,
    required String deviceId,
  }) {
    // The handoff position isn't worth a warning on the read-only backup server.
    if (songs.isEmpty || index < 0 || index >= songs.length || isReadOnly) {
      return Future.value();
    }
    return _get(
      'savePlayQueue',
      {
        'id': songs.map((song) => song.id),
        'current': songs[index].id,
        'position': position.inMilliseconds.clamp(0, 1 << 53),
        'c': deviceId,
      },
      null,
      true,
    );
  }

  /// The last known total, read without any network call.
  int? get cachedSongCount => _countFrom(_peek(_scanStatusKey));

  static const String _scanStatusKey = 'scanStatus';

  static int? _countFrom(Map<String, dynamic>? body) {
    final scan = body?['scanStatus'];
    final count = scan is Map ? (scan['count'] as num?)?.toInt() : null;
    return count != null && count >= 0 ? count : null;
  }

  Future<int?> songCount() async {
    final body = await _get(
      'getScanStatus',
      const {},
      const Duration(seconds: 5),
    );
    final count = _countFrom(body);
    if (count != null) _cache?.put(_scanStatusKey, const {}, body);
    return count;
  }

  /// What the server says about its library right now, never from saved data.
  Future<ScanStatus> scanStatus() async {
    final body = await _fetch('getScanStatus', const {}, _scanTimeout);
    _cache?.put(_scanStatusKey, const {}, body);
    final scan = body['scanStatus'];
    return scan is Map
        ? ScanStatus(
            isScanning: scan['scanning'] == true,
            lastScan: scan['lastScan']?.toString(),
            count: _countFrom(body),
          )
        : const ScanStatus(isScanning: false);
  }

  /// A page of the whole library straight from the server, for building the local copy.
  Future<List<Song>> freshSongs({
    required int offset,
    required int count,
  }) async {
    final body = await _fetch('search3', {
      'query': '',
      'artistCount': 0,
      'albumCount': 0,
      'songCount': count,
      'songOffset': offset,
    }, _catalogPageTimeout);
    return jsonList(
      body['searchResult3'] as Map<String, dynamic>?,
      'song',
    ).map(Song.fromJson).toList(growable: false);
  }

  /// A playlist as the server has it right now, for edits that go by position.
  Future<List<Song>> freshPlaylistSongs(String playlistId) async =>
      _parsePlaylistSongs(
        await _fetch('getPlaylist', {'id': playlistId}, _requestTimeout),
      );

  Future<List<Song>> freshStarredSongs() async {
    final body = await _fetch('getStarred2', const {}, _catalogPageTimeout);
    return jsonList(
      body['starred2'] as Map<String, dynamic>?,
      'song',
    ).map(Song.fromJson).toList(growable: false);
  }

  Future<void> startScan() => _write('startScan', const {}, const {}, true);

  Uri streamUri(String songId, {int? maxBitRate}) =>
      _uri('stream', {'id': songId, 'maxBitRate': maxBitRate});

  /// The original file, never transcoded (the server has no ffmpeg).
  Uri downloadUri(String songId) => _uri('download', {'id': songId});

  final Map<String, Future<String?>> _artistCoverCache = {};

  /// Artist pictures come from internet services the server cannot reach, so use the
  /// cover of the artist's first album instead. Cached per artist for the session.
  Future<String?> artistCoverId(String artistId) =>
      _artistCoverCache.putIfAbsent(artistId, () async {
        try {
          final albums = await artistAlbums(artistId);
          return albums
              .map((a) => a.coverArtId)
              .whereType<String>()
              .firstOrNull;
        } on Exception {
          _artistCoverCache.remove(artistId);
          return null;
        }
      });

  Uri coverArtUri(String? coverArtId, {int size = 300}) =>
      _uri('getCoverArt', {'id': coverArtId, 'size': size}, true);
}
