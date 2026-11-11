import 'dart:convert';

import 'package:http/http.dart' as http;

class DatabaseSong {
  const DatabaseSong({
    required this.artist,
    required this.title,
    this.album = '',
    this.cover,
  });
  final String artist, title, album;
  final String? cover;
}

/// Search metadata only. Selecting a recording never downloads its audio.
class SongDatabase {
  SongDatabase({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  void close() => _client.close();
  Future<List<DatabaseSong>> search(String query) async {
    final response = await _client
        .get(
          Uri.https('itunes.apple.com', '/search', {
            'term': query.trim(),
            'entity': 'song',
            'media': 'music',
            'limit': '25',
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200)
      throw Exception('Song database unavailable');
    final body =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final seen = <String>{};
    return [
      for (final item in (body['results'] as List? ?? []).whereType<Map>())
        if (item['artistName'] is String &&
            item['trackName'] is String &&
            seen.add(
              '${item['artistName']}|${item['trackName']}|${item['collectionName']}',
            ))
          DatabaseSong(
            artist: item['artistName'] as String,
            title: item['trackName'] as String,
            album: item['collectionName'] as String? ?? '',
            cover: item['artworkUrl100'] as String?,
          ),
    ];
  }
}
