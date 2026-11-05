import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/spotify/spotify_export.dart';
import 'package:yomi/core/spotify/track_matcher.dart';

Song _song(String id, String title, String artist, {int seconds = 200}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: 'Album',
  durationSeconds: seconds,
);

ExportTrack _track(String title, String artist, {int? seconds}) =>
    ExportTrack(title: title, artist: artist, durationSeconds: seconds);

void main() {
  final matcher = TrackMatcher([
    _song('plain', 'Halo', 'Beyoncé'),
    _song('feat', 'Stay', 'Rihanna feat. Mikky Ekko', seconds: 240),
    _song('live', 'Clocks (Live in Paris)', 'Coldplay'),
    _song('studio', 'Clocks', 'Coldplay', seconds: 307),
    _song('remaster', 'Come Together - 2019 Mix', 'The Beatles'),
    _song('jp', '新時代', 'Ado'),
    _song('typo', 'Dancing Queeen', 'ABBA'),
    _song('dupe', 'Intro', 'Band A'),
    _song('dupe2', 'Intro', 'Band B'),
    _song('short', 'Same', 'Twin', seconds: 100),
    _song('long', 'Same', 'Twin', seconds: 300),
  ]);

  group('sure matches', () {
    final cases = <(String, ExportTrack, String)>[
      ('accents', _track('Halo', 'Beyonce'), 'plain'),
      ('case', _track('HALO', 'BEYONCÉ'), 'plain'),
      (
        'featured artists',
        _track('Stay (feat. Mikky Ekko)', 'Rihanna'),
        'feat',
      ),
      (
        'remaster suffix',
        _track('Come Together - Remastered 2009', 'The Beatles'),
        'remaster',
      ),
      ('non-Latin titles', _track('新時代', 'Ado'), 'jp'),
      (
        'several artists listed',
        _track('Halo', 'Beyoncé, Someone Else'),
        'plain',
      ),
      (
        'the studio version over a live one',
        _track('Clocks', 'Coldplay', seconds: 307),
        'studio',
      ),
      (
        'the closest length among duplicates',
        _track('Same', 'Twin', seconds: 301),
        'long',
      ),
    ];
    for (final (name, track, id) in cases) {
      test(name, () {
        final result = matcher.match(track);
        expect(result.status, MatchStatus.matched);
        expect(result.song?.id, id);
      });
    }
  });

  group('needs a check', () {
    test('a length far from the original', () {
      final result = matcher.match(_track('Halo', 'Beyoncé', seconds: 400));
      expect(result.status, MatchStatus.check);
      expect(result.song?.id, 'plain');
    });

    test('a small typo', () {
      final result = matcher.match(_track('Dancing Queen', 'ABBA'));
      expect(result.status, MatchStatus.check);
      expect(result.song?.id, 'typo');
    });

    test('the right title by a different artist is not assumed', () {
      final result = matcher.match(_track('Intro', 'Band C'));
      expect(result.status, MatchStatus.check);
      expect(result.alternatives, hasLength(2));
    });
  });

  group('missing', () {
    test('a live recording never stands in for the studio one', () {
      final only = TrackMatcher([
        _song('live', 'Clocks (Live in Paris)', 'Coldplay'),
      ]);
      expect(
        only.match(_track('Clocks', 'Coldplay')).status,
        isNot(MatchStatus.matched),
      );
      expect(only.match(_track('Clocks', 'Coldplay')).song, isNull);
    });

    test('a remix never stands in for the original, or the other way', () {
      final original = TrackMatcher([_song('o', 'Song', 'A')]);
      expect(original.match(_track('Song (Remix)', 'A')).song, isNull);
      final remix = TrackMatcher([_song('r', 'Song - Club Remix', 'A')]);
      expect(remix.match(_track('Song', 'A')).song, isNull);
    });

    test('nothing like it in the library', () {
      final result = matcher.match(_track('Unknown Song', 'Nobody'));
      expect(result.status, MatchStatus.missing);
      expect(result.song, isNull);
    });
  });

  test('version words match each other when both have them', () {
    final both = TrackMatcher([_song('l', 'Clocks - Live', 'Coldplay')]);
    expect(
      both.match(_track('Clocks (Live)', 'Coldplay')).status,
      MatchStatus.matched,
    );
  });

  test('matching a thousand tracks against a big library is quick', () {
    final big = TrackMatcher([
      for (var i = 0; i < 5000; i++)
        _song('$i', 'Title $i', 'Artist ${i % 300}'),
    ]);
    final timer = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      big.match(_track('Title ${i * 7} extra', 'Artist $i'));
    }
    expect(timer.elapsedMilliseconds, lessThan(5000));
  });
}
