import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/artwork_lookup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'matches exact album and artist, persists artwork across sessions',
    () async {
      var calls = 0;
      ArtworkLookup make() => ArtworkLookup(
        client: MockClient((request) async {
          calls++;
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'artistName': 'Someone else',
                  'collectionName': 'Album',
                  'artworkUrl100': 'https://wrong/100x100bb.jpg',
                },
                {
                  'artistName': 'Artist',
                  'collectionName': 'Album',
                  'artworkUrl100': 'https://art/100x100bb.jpg',
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(
        await make().find('Artist', 'Album', 'Song'),
        'https://art/600x600bb.jpg',
      );
      expect(
        await make().find('Artist', 'Album', 'Other track'),
        'https://art/600x600bb.jpg',
      );
      expect(calls, 1);
    },
  );
  test(
    'falls back to MusicBrainz and selects a matching release with front art',
    () async {
      final lookup = ArtworkLookup(
        client: MockClient((request) async {
          if (request.url.host == 'itunes.apple.com')
            return http.Response('{"results":[]}', 200);
          return http.Response(
            jsonEncode({
              'releases': [
                {
                  'id': 'release-id',
                  'title': 'Album',
                  'artist-credit': [
                    {'name': 'Artist'},
                  ],
                  'cover-art-archive': {'front': true},
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(
        await lookup.find('Artist', 'Album', 'Song'),
        'https://coverartarchive.org/release/release-id/front-500',
      );
    },
  );
}
