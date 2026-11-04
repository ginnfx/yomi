import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exact metadata matches only; cached separately from the music files.
class ArtworkLookup {
  static final instance = ArtworkLookup();
  ArtworkLookup({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;
  final Map<String, Future<String?>> _pending = {};
  Future<void> _tail = Future.value();
  static String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  Future<String?> find(String artist, String album, String title) {
    if (artist.trim().isEmpty || normalized(artist).startsWith('unknown'))
      return Future.value(null);
    final identity =
        album.trim().isEmpty || normalized(album).startsWith('unknown')
        ? title
        : album;
    final key =
        'art_lookup_v1_${sha256.convert(utf8.encode('$artist|$identity'))}';
    return _pending.putIfAbsent(key, () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString(key);
        if (saved != null) return saved.isEmpty ? null : saved;
        final previous = _tail;
        final work = () async {
          await previous;
          try {
            final url = await _lookup(artist, album, title);
            if (url != null) await prefs.setString(key, url);
            return url;
          } finally {
            await Future<void>.delayed(const Duration(seconds: 3));
          }
        }();
        _tail = work.then<void>((_) {}, onError: (Object _) {});
        return await work;
      } on Object {
        _pending.remove(key);
        return null;
      }
    });
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final response = await _http
        .get(
          uri,
          headers: {'User-Agent': 'Yomi/1.1 (https://github.com/ginnfx/yomi)'},
        )
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String?> _lookup(String artist, String album, String title) async {
    final hasAlbum =
        album.trim().isNotEmpty && !normalized(album).startsWith('unknown');
    try {
      final data = await _json(
        Uri.https('itunes.apple.com', '/search', {
          'term': '$artist ${hasAlbum ? album : title}',
          'entity': hasAlbum ? 'album' : 'song',
          'limit': '10',
        }),
      );
      for (final item in (data['results'] as List? ?? [])) {
        if (normalized(item['artistName'] as String? ?? '') !=
            normalized(artist))
          continue;
        final name =
            item[hasAlbum ? 'collectionName' : 'trackName'] as String? ?? '';
        if (normalized(name) != normalized(hasAlbum ? album : title)) continue;
        final url = item['artworkUrl100'] as String?;
        if (url != null) return url.replaceAll('100x100bb', '600x600bb');
      }
    } on Object {
      /* Try MusicBrainz independently. */
    }
    final escape = (String s) => s.replaceAll(RegExp(r'["\\]'), ' ');
    final data = await _json(
      Uri.https(
        'musicbrainz.org',
        hasAlbum ? '/ws/2/release/' : '/ws/2/recording/',
        {
          'query': hasAlbum
              ? 'artist:"${escape(artist)}" AND release:"${escape(album)}"'
              : 'artist:"${escape(artist)}" AND recording:"${escape(title)}"',
          'fmt': 'json',
          'limit': '5',
        },
      ),
    );
    final releases = <dynamic>[];
    for (final item
        in (data[hasAlbum ? 'releases' : 'recordings'] as List? ?? [])) {
      if (normalized(item['title'] as String? ?? '') !=
          normalized(hasAlbum ? album : title))
        continue;
      final credits = item['artist-credit'] as List? ?? [];
      if (!credits.any(
        (c) =>
            c is Map &&
            normalized(
                  c['name'] as String? ?? c['artist']?['name'] as String? ?? '',
                ) ==
                normalized(artist),
      ))
        continue;
      releases.addAll(hasAlbum ? [item] : (item['releases'] as List? ?? []));
    }
    for (final release in releases.take(3)) {
      if (release['cover-art-archive']?['front'] == true) {
        return 'https://coverartarchive.org/release/${release['id']}/front-500';
      }
      try {
        final art = await _json(
          Uri.https('coverartarchive.org', '/release/${release['id']}'),
        );
        for (final image in (art['images'] as List? ?? [])) {
          if (image['front'] != true) continue;
          final url = image['thumbnails']?['500'] ?? image['image'];
          if (url is String && url.startsWith('https://')) return url;
        }
      } on Object {
        /* Another edition may have a cover. */
      }
    }
    return null;
  }
}
