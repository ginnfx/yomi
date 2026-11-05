import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/spotify/spotify_export.dart';

String _extended(List<Map<String, Object?>> rows) => jsonEncode(rows);

Map<String, Object?> _row({
  String ts = '2021-03-14T20:00:00Z',
  int ms = 200000,
  String? track = 'Song',
  String? artist = 'Artist',
  String? album = 'Album',
  String? uri = 'spotify:track:abc',
}) => {
  'ts': ts,
  'ms_played': ms,
  'master_metadata_track_name': track,
  'master_metadata_album_artist_name': artist,
  'master_metadata_album_album_name': album,
  'spotify_track_uri': uri,
  'ip_addr': '203.0.113.9',
  'platform': 'ios',
  'conn_country': 'US',
};

void main() {
  group('listening history', () {
    test('reads the extended export and keeps only what it needs', () {
      final rows = parseHistoryFile(_extended([_row()]));
      expect(rows.single.track, 'Song');
      expect(rows.single.artist, 'Artist');
      expect(rows.single.album, 'Album');
      expect(rows.single.msPlayed, 200000);
      expect(rows.single.at, DateTime.utc(2021, 3, 14, 20));
      expect(jsonEncode(rows.single.toJson()), isNot(contains('203.0.113.9')));
    });

    test('reads the basic export', () {
      final rows = parseHistoryFile(
        jsonEncode([
          {
            'endTime': '2021-03-14 20:00',
            'artistName': 'Artist',
            'trackName': 'Song',
            'msPlayed': 90000,
          },
        ]),
      );
      expect(rows.single.track, 'Song');
      expect(rows.single.msPlayed, 90000);
      expect(rows.single.at, DateTime.utc(2021, 3, 14, 20));
    });

    test('drops podcasts and plays under 30 seconds', () {
      final rows = parseHistoryFile(
        _extended([
          _row(ms: 29999),
          _row(ms: 30000),
          _row(track: null, artist: null),
        ]),
      );
      expect(rows, hasLength(1));
      expect(rows.single.msPlayed, 30000);
    });

    test('skips rows it can\'t read instead of failing', () {
      final rows = parseHistoryFile(
        jsonEncode([
          'nonsense',
          {'ts': 'not a date', 'ms_played': 100000},
          _row(),
        ]),
      );
      expect(rows, hasLength(1));
    });

    test('a file that isn\'t a history gives nothing', () {
      expect(parseHistoryFile('{"not":"a list"}'), isEmpty);
      expect(parseHistoryFile('garbage'), isEmpty);
    });
  });

  group('totals', () {
    final march = _row();
    final later = _row(ts: '2021-03-20T10:00:00Z');
    final april = _row(ts: '2021-04-02T23:00:00Z');

    test('adds up plays by month and track', () {
      final totals = ImportedHistory.empty().adding(
        parseHistoryFile(_extended([march, later, april])),
      );
      expect(totals.totalMs, 600000);
      expect(totals.playsOf(2021), 3);
      expect(totals.topTracks(2021).single.plays, 3);
      expect(totals.months['2021-03']!.values.single.plays, 2);
    });

    test('importing the same file twice doesn\'t double-count', () {
      final rows = parseHistoryFile(_extended([march, later]));
      final once = ImportedHistory.empty().adding(rows);
      final twice = once.adding(rows);
      expect(twice.totalMs, once.totalMs);
      expect(twice.playsOf(2021), 2);
    });

    test('overlapping exports only add what\'s new', () {
      final first = ImportedHistory.empty().adding(
        parseHistoryFile(_extended([march, later])),
      );
      final both = first.adding(parseHistoryFile(_extended([later, april])));
      expect(both.playsOf(2021), 3);
    });

    test('survives being saved and loaded', () {
      final totals = ImportedHistory.empty().adding(
        parseHistoryFile(_extended([march, april])),
      );
      final restored = ImportedHistory.fromJson(
        jsonDecode(jsonEncode(totals.toJson())) as Map<String, dynamic>,
      );
      expect(restored.totalMs, totals.totalMs);
      expect(restored.topTracks(2021), hasLength(1));
      // What was seen comes back too, so re-importing later still can't double-count.
      expect(
        restored.adding(parseHistoryFile(_extended([march]))).totalMs,
        totals.totalMs,
      );
    });

    test('top artists rank by time and years come out sorted', () {
      final totals = ImportedHistory.empty().adding(
        parseHistoryFile(
          _extended([
            _row(artist: 'Small', track: 'A', ms: 40000),
            _row(artist: 'Big', track: 'B', ms: 400000, ts: '2021-05-01T00:00:00Z'),
            _row(artist: 'Old', track: 'C', ts: '2019-05-01T00:00:00Z'),
          ]),
        ),
      );
      expect(totals.topArtists(2021).first.name, 'Big');
      expect(totals.years, [2019, 2021]);
    });

    test('a time of day histogram survives the totals', () {
      final totals = ImportedHistory.empty().adding(
        parseHistoryFile(_extended([march])),
      );
      expect(totals.hours[2021]![20], 1);
    });
  });

  group('library and playlists', () {
    test('reads liked songs from YourLibrary', () {
      final library = parseLibraryFile(
        jsonEncode({
          'tracks': [
            {'artist': 'A', 'album': 'B', 'track': 'C', 'uri': 'spotify:track:1'},
            {'nonsense': true},
          ],
        }),
      );
      expect(library.single.title, 'C');
      expect(library.single.artist, 'A');
    });

    test('reads playlists in order', () {
      final playlists = parsePlaylistsFile(
        jsonEncode({
          'playlists': [
            {
              'name': 'Road trip',
              'items': [
                {
                  'track': {'trackName': 'Two', 'artistName': 'B', 'albumName': 'X'},
                },
                {
                  'track': {'trackName': 'One', 'artistName': 'A', 'albumName': 'Y'},
                },
                {'episode': {'name': 'A podcast'}},
              ],
            },
          ],
        }),
      );
      expect(playlists.single.name, 'Road trip');
      expect(playlists.single.tracks.map((t) => t.title), ['Two', 'One']);
    });

    test('reads a CSV by its column names, keeping order and quotes', () {
      final playlist = parsePlaylistCsv(
        'Road trip',
        'Track Name,Artist Name(s),Album Name,Duration (ms)\n'
            '"Hello, World",Someone,"An ""Album""",180000\n'
            'Second,"A, B",Other,200500\n',
      );
      expect(playlist.tracks.map((t) => t.title), ['Hello, World', 'Second']);
      expect(playlist.tracks.first.album, 'An "Album"');
      expect(playlist.tracks.first.durationSeconds, 180);
      expect(playlist.tracks.last.artist, 'A, B');
    });

    test('a CSV without the right columns gives no tracks', () {
      expect(parsePlaylistCsv('x', 'a,b\n1,2\n').tracks, isEmpty);
      expect(parsePlaylistCsv('x', '').tracks, isEmpty);
    });
  });

  group('whole exports', () {
    List<int> zipOf(Map<String, String> files) {
      final archive = Archive();
      files.forEach((name, text) {
        final bytes = utf8.encode(text);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      return ZipEncoder().encode(archive);
    }

    test('finds everything inside a zip, whatever folder it\'s in', () {
      final export = readExport('my_data.zip', [
        ...zipOf({
          'Spotify Extended/Streaming_History_Audio_2021.json': _extended([_row()]),
          'Spotify Account/YourLibrary.json': jsonEncode({
            'tracks': [
              {'artist': 'A', 'album': 'B', 'track': 'C'},
            ],
          }),
          'Spotify Account/Playlist1.json': jsonEncode({
            'playlists': [
              {
                'name': 'P',
                'items': [
                  {
                    'track': {'trackName': 'T', 'artistName': 'A', 'albumName': 'B'},
                  },
                ],
              },
            ],
          }),
          'Spotify Account/Userdata.json': '{"email":"private@example.com"}',
          'Spotify Extended/Read Me First.pdf': 'not json',
        }),
      ]);
      expect(export.history, hasLength(1));
      expect(export.likedSongs, hasLength(1));
      expect(export.playlists.single.name, 'P');
    });

    test('reads a single JSON file by its name', () {
      final export = readExport(
        'StreamingHistory_music_0.json',
        utf8.encode(
          jsonEncode([
            {'endTime': '2021-03-14 20:00', 'artistName': 'A', 'trackName': 'S', 'msPlayed': 90000},
          ]),
        ),
      );
      expect(export.history, hasLength(1));
    });

    test('something else entirely gives an empty result', () {
      expect(readExport('photo.jpg', [1, 2, 3]).isEmpty, isTrue);
      expect(readExport('broken.zip', [1, 2, 3]).isEmpty, isTrue);
    });
  });
}
