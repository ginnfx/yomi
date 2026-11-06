import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/youtube/yt_dlp.dart';

YoutubeResult result(
  String title, {
  String channel = 'Someone',
  int duration = 200,
  String id = 'x',
}) => YoutubeResult(
  id: id,
  title: title,
  channel: channel,
  durationSeconds: duration,
);

void main() {
  group('arguments', () {
    test('every run ignores personal yt-dlp settings', () {
      // Act
      final search = searchArgs('Mira - Blue Hour', count: 5);
      final download = downloadArgs('em0MknB6wFo', '/tmp/out');

      // Assert
      expect(search, contains('--ignore-config'));
      expect(download, contains('--ignore-config'));
    });

    test('search asks for several results without downloading', () {
      // Act
      final args = searchArgs('Mira - Blue Hour', count: 5);

      // Assert
      expect(args, containsAll(['--flat-playlist', '--dump-json']));
      expect(args.last, 'ytsearch5:Mira - Blue Hour');
    });

    test('download prefers m4a audio and reports progress and the file', () {
      // Act
      final args = downloadArgs('em0MknB6wFo', '/tmp/out');

      // Assert
      expect(args, containsAllInOrder(['-f', kAudioFormat]));
      expect(args, containsAllInOrder(['--extractor-args', kExtractorArgs]));
      expect(args, contains('--newline'));
      expect(args, containsAllInOrder(['--print', 'after_move:filepath']));
      expect(args.last, 'https://www.youtube.com/watch?v=em0MknB6wFo');
    });

    test('a video id that could be read as an option is refused', () {
      // Act / Assert
      expect(() => downloadArgs('--exec=rm', '/tmp'), throwsArgumentError);
    });
  });

  group('reading output', () {
    test('parses one search result per line and skips noise', () {
      // Arrange
      final out = [
        jsonEncode({
          'id': 'v1',
          'title': 'Blue Hour (Official Audio)',
          'channel': 'Mira',
          'duration': 201.0,
        }),
        'WARNING: something',
        jsonEncode({'id': 'v2', 'title': 'Blue Hour live', 'uploader': 'Fan'}),
      ].join('\n');

      // Act
      final results = parseSearchOutput(out);

      // Assert
      expect(results.map((r) => r.id), ['v1', 'v2']);
      expect(results.first.durationSeconds, 201);
      expect(results.last.channel, 'Fan');
    });

    test('reads download progress lines', () {
      // Act / Assert
      expect(parseProgress('download: 42.5%'), closeTo(0.425, 0.0001));
      expect(parseProgress('download:100.0%'), 1);
      expect(parseProgress('/music/abc.m4a'), isNull);
    });
  });

  group('ranking', () {
    test('the official audio beats a live take and a cover', () {
      // Arrange
      final results = [
        result('Blue Hour (Live at Wembley)', channel: 'Mira', id: 'live'),
        result('Blue Hour - cover by Sam', channel: 'Sam', id: 'cover'),
        result(
          'Mira - Blue Hour (Official Audio)',
          channel: 'Mira',
          id: 'real',
        ),
      ];

      // Act
      final ranked = rankResults(results, artist: 'Mira', title: 'Blue Hour');

      // Assert
      expect(ranked.first.id, 'real');
    });

    test('a live version wins when that is what was asked for', () {
      // Arrange
      final results = [
        result('Blue Hour', channel: 'Mira', id: 'studio'),
        result('Blue Hour (Live)', channel: 'Mira', id: 'live'),
      ];

      // Act
      final ranked = rankResults(
        results,
        artist: 'Mira',
        title: 'Blue Hour (Live)',
      );

      // Assert
      expect(ranked.first.id, 'live');
    });

    test('a length close to the expected one counts', () {
      // Arrange
      final results = [
        result('Mira - Blue Hour', channel: 'Mira', duration: 600, id: 'long'),
        result('Mira - Blue Hour', channel: 'Mira', duration: 203, id: 'right'),
      ];

      // Act
      final ranked = rankResults(
        results,
        artist: 'Mira',
        title: 'Blue Hour',
        durationSeconds: 200,
      );

      // Assert
      expect(ranked.first.id, 'right');
    });

    test('hour-long loops lose even when their title matches better', () {
      // Arrange
      final results = [
        result(
          'SZA Good Days (1 hour loop)',
          channel: 'Fan',
          duration: 3600,
          id: 'loop',
        ),
        result(
          'SZA - Good Days (Official Video)',
          channel: 'SZA',
          duration: 279,
          id: 'real',
        ),
      ];

      // Act
      final ranked = rankResults(results, artist: 'SZA', title: 'Good Days');

      // Assert
      expect(ranked.first.id, 'real');
    });

    test('explicit is preferred when asked for', () {
      // Arrange
      final results = [
        result('Mira - Blue Hour (Clean)', channel: 'Mira', id: 'clean'),
        result('Mira - Blue Hour (Explicit)', channel: 'Mira', id: 'explicit'),
      ];

      // Act
      final ranked = rankResults(
        results,
        artist: 'Mira',
        title: 'Blue Hour',
        wantExplicit: true,
      );

      // Assert
      expect(ranked.first.id, 'explicit');
    });
  });

  test('saved files are named "Title - Artist" without unsafe characters', () {
    // Act
    final name = libraryFileName(artist: 'AC/DC', title: 'Back: In Black?');

    // Assert
    expect(name, 'Back In Black - ACDC.m4a');
  });
}
