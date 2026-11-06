import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/export/wanted_export.dart';
import 'package:yomi/core/reports/reports_api.dart';

const _songs = [
  WantedSong(artist: 'Mira', title: 'Blue Hour', count: 3),
  WantedSong(artist: 'Oak', title: 'Green, Room', count: 1),
];

void main() {
  group('text', () {
    test('is one "Artist - Title" per line', () {
      final file = exportWanted(_songs, WantedFormat.text);

      expect(file.content, 'Mira - Blue Hour\nOak - Green, Room\n');
      expect(file.name, 'yomi-wanted-songs.txt');
      expect(file.mimeType, 'text/plain');
    });

    test('keeps a title with a line break on one line', () {
      final file = exportWanted(const [
        WantedSong(artist: 'A', title: 'two\nlines', count: 1),
      ], WantedFormat.text);

      expect(file.content, 'A - two lines\n');
    });
  });

  group('csv', () {
    test('has a header and quotes values holding commas', () {
      final file = exportWanted(_songs, WantedFormat.csv);

      expect(
        file.content,
        'artist,title,wanted_by\r\n'
        'Mira,Blue Hour,3\r\n'
        'Oak,"Green, Room",1\r\n',
      );
      expect(file.name, 'yomi-wanted-songs.csv');
    });

    test('doubles quotes inside a value', () {
      final file = exportWanted(const [
        WantedSong(artist: 'A', title: 'The "One"', count: 1),
      ], WantedFormat.csv);

      expect(file.content, contains('"The ""One"""'));
    });

    test(
      'stops a title starting with = from running as a spreadsheet formula',
      () {
        final file = exportWanted(const [
          WantedSong(artist: '=HYPERLINK("x")', title: '+1', count: 1),
        ], WantedFormat.csv);

        final lines = file.content.split('\r\n');
        expect(lines[1], startsWith('"\'=HYPERLINK'));
        expect(lines[1], contains(",'+1,"));
      },
    );
  });

  group('json', () {
    test('is a list of songs that reads back the same', () {
      final file = exportWanted(_songs, WantedFormat.json);

      final decoded = jsonDecode(file.content) as List<dynamic>;
      expect(decoded, [
        {'artist': 'Mira', 'title': 'Blue Hour', 'wantedBy': 3},
        {'artist': 'Oak', 'title': 'Green, Room', 'wantedBy': 1},
      ]);
      expect(file.name, 'yomi-wanted-songs.json');
      expect(file.mimeType, 'application/json');
    });
  });

  test('an empty list still gives a valid file in every format', () {
    expect(exportWanted(const [], WantedFormat.text).content, '');
    expect(
      exportWanted(const [], WantedFormat.csv).content,
      'artist,title,wanted_by\r\n',
    );
    expect(exportWanted(const [], WantedFormat.json).content, '[]');
  });
}
