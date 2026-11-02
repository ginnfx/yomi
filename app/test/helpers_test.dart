import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/format.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/state/session.dart';

void main() {
  group('normalizeServerUrl', () {
    test('adds http and the Navidrome port to a bare address', () {
      expect(
        normalizeServerUrl('100.88.180.104'),
        'http://100.88.180.104:4533',
      );
      expect(
        normalizeServerUrl('  192.168.1.18  '),
        'http://192.168.1.18:4533',
      );
    });

    test('keeps an explicit port and strips trailing slashes', () {
      expect(
        normalizeServerUrl('http://music.home:5000/'),
        'http://music.home:5000',
      );
    });

    test('does not force a port onto https addresses', () {
      expect(
        normalizeServerUrl('https://music.example.com'),
        'https://music.example.com',
      );
    });

    test('returns empty for blank input', () {
      expect(normalizeServerUrl('   '), '');
    });
  });

  group('formatDuration', () {
    test('formats minutes and seconds', () {
      expect(formatDuration(const Duration(minutes: 3, seconds: 5)), '3:05');
    });

    test('includes hours for long durations', () {
      expect(
        formatDuration(const Duration(hours: 1, minutes: 2, seconds: 9)),
        '1:02:09',
      );
    });

    test('never shows negative time', () {
      expect(formatDuration(const Duration(seconds: -4)), '0:00');
    });
  });

  group('greetingFor', () {
    test('changes with the time of day', () {
      expect(greetingFor(DateTime(2026, 1, 1, 8)), 'Good morning');
      expect(greetingFor(DateTime(2026, 1, 1, 14)), 'Good afternoon');
      expect(greetingFor(DateTime(2026, 1, 1, 20)), 'Good evening');
      expect(greetingFor(DateTime(2026, 1, 1, 2)), 'Good night');
    });
  });

  group('untagged songs', () {
    test('a "Title - Artist" file name is split into title and artist', () {
      final song = Song.fromJson({
        'id': '1',
        'title': 'LVL - A\$AP Rocky',
        'artist': '[Unknown Artist]',
        'duration': 100,
      });

      expect(song.title, 'LVL');
      expect(song.artist, 'A\$AP Rocky');
    });

    test('properly tagged songs are never rewritten, even with a dash in the title', () {
      final song = Song.fromJson({
        'id': '1',
        'title': 'Super Street Fighter IV - Theme',
        'artist': 'Capcom',
        'duration': 100,
      });

      expect(song.title, 'Super Street Fighter IV - Theme');
      expect(song.artist, 'Capcom');
    });

    test('with no dash and no artist it falls back to readable defaults', () {
      final song = Song.fromJson({
        'id': '1',
        'title': 'Untitled demo',
        'duration': 1,
      });

      expect(song.title, 'Untitled demo');
      expect(song.artist, 'Unknown artist');
    });
  });

  test('Song.copyWith only changes the starred flag', () {
    const song = Song(
      id: '1',
      title: 'T',
      artist: 'A',
      album: 'B',
      durationSeconds: 10,
      coverArtId: 'c',
    );

    final liked = song.copyWith(isStarred: true);

    expect(liked.isStarred, isTrue);
    expect(liked.title, 'T');
    expect(liked.coverArtId, 'c');
  });
}
