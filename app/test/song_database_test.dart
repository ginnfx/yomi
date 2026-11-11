import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/song_database.dart';
import 'package:yomi/core/artwork_lookup.dart';
import 'package:yomi/core/ai/assistant.dart';
import 'package:yomi/core/search_index.dart';

void main() {
  test(
    'catalog preserves recording editions, Unicode names and correct artwork',
    () async {
      final db = SongDatabase(
        client: MockClient((request) async {
          expect(request.url.host, 'itunes.apple.com');
          expect(request.url.queryParameters['term'], '夜に駆ける');
          expect(request.url.queryParameters['entity'], 'song');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'results': [
                  {
                    'artistName': 'YOASOBI',
                    'trackName': '夜に駆ける',
                    'collectionName': 'THE BOOK',
                    'artworkUrl100': 'https://example.com/original.jpg',
                  },
                  {
                    'artistName': 'YOASOBI',
                    'trackName': '夜に駆ける',
                    'collectionName': 'THE BOOK',
                    'artworkUrl100': 'https://example.com/original.jpg',
                  },
                  {
                    'artistName': 'YOASOBI',
                    'trackName': '夜に駆ける (Live)',
                    'collectionName': 'Live',
                    'artworkUrl100': 'https://example.com/live.jpg',
                  },
                ],
              }),
            ),
            200,
          );
        }),
      );
      final songs = await db.search(' 夜に駆ける ');
      expect(songs.length, 2);
      expect(songs.first.title, '夜に駆ける');
      expect(songs.first.cover, 'https://example.com/original.jpg');
      expect(songs.last.title, contains('Live'));
      db.close();
    },
  );
  test('provider errors are distinct from no results', () async {
    final db = SongDatabase(
      client: MockClient((_) async => http.Response('', 429)),
    );
    await expectLater(db.search('test'), throwsException);
    db.close();
  });
  test('artwork identity retains non-Latin names', () {
    expect(
      ArtworkLookup.normalized('宇多田ヒカル'),
      isNot(ArtworkLookup.normalized('椎名林檎')),
    );
    expect(ArtworkLookup.normalized('Beyoncé'), 'beyonce');
    expect(normalizeForSearch('ＹＯＡＳＯＢＩ'), 'yoasobi');
  });
  test('web citations survive library matching and reject non-web links', () {
    final answer = ChatAnswer.fromJson({
      'reply': 'Found it',
      'sources': [
        {'title': 'Source', 'url': 'https://example.com/song'},
        {'title': 'Unsafe', 'url': 'javascript:alert(1)'},
        {'title': 'Relative', 'url': '/song'},
      ],
    }).matchedWith(SearchIndex([]));
    expect(answer.sources.length, 1);
    expect(answer.sources.single.url.host, 'example.com');
  });
}
