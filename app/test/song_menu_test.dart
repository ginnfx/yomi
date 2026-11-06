import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/format.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/song_share.dart';
import 'package:yomi/ui/pages/now_playing_page.dart';
import 'package:yomi/ui/share/share_card.dart';
import 'package:yomi/ui/widgets/song_menu.dart';

import 'support/screen_harness.dart';

const _song = Song(
  id: 's1',
  title: 'Raindance',
  artist: 'Dave',
  album: 'The Boy Who Played the Harp',
  durationSeconds: 200,
  albumId: 'al1',
);

void _none() {}

List<String> _labels({
  Song song = _song,
  bool isFromPlayer = false,
  bool hasQueue = true,
  bool showsLyrics = true,
  bool isSaved = false,
  VoidCallback? onRemoveFromPlaylist,
}) => [
  for (final action in songMenuActions(
    song: song,
    isSaved: isSaved,
    hasQueue: hasQueue,
    isFromPlayer: isFromPlayer,
    showsLyrics: showsLyrics,
    onShare: _none,
    onToggleLyrics: _none,
    onAddToPlaylist: _none,
    onToggleLike: _none,
    onToggleDownload: _none,
    onPlayNext: _none,
    onAddToQueue: _none,
    onGoToQueue: _none,
    onGoToAlbum: _none,
    onShowLess: _none,
    onRemoveFromPlaylist: onRemoveFromPlaylist,
  ))
    action.label,
];

void main() {
  group('songMenuActions', () {
    test('starts with Share, like Spotify', () {
      expect(_labels().first, 'Share');
    });

    test('offers removing only when opened from your playlist', () {
      expect(_labels(), isNot(contains('Remove from this playlist')));
      expect(
        _labels(onRemoveFromPlaylist: _none),
        contains('Remove from this playlist'),
      );
    });

    test('shows the lyrics switch only on the player', () {
      expect(_labels(), isNot(contains('Lyrics · On')));
      expect(_labels(isFromPlayer: true), contains('Lyrics · On'));
      expect(
        _labels(isFromPlayer: true, showsLyrics: false),
        contains('Lyrics · Off'),
      );
    });

    test('offers the queue only when something is playing', () {
      expect(_labels(hasQueue: false), isNot(contains('Go to queue')));
      expect(_labels(), contains('Go to queue'));
    });

    test('offers the album only when the song knows it', () {
      const noAlbum = Song(
        id: 's2',
        title: 'Loose file',
        artist: 'Someone',
        album: 'Unknown album',
        durationSeconds: 60,
      );
      expect(_labels(), contains('Go to album'));
      expect(_labels(song: noAlbum), isNot(contains('Go to album')));
    });

    test('download turns into remove once saved', () {
      expect(_labels(), contains('Download'));
      expect(_labels(isSaved: true), contains('Remove download'));
    });
  });

  group('sharing', () {
    test(
      'the message names the song and links somewhere anyone can listen',
      () {
        final text = songShareText(_song);

        expect(text, startsWith('Raindance · Dave\n'));
        expect(songListenLink(_song).host, 'music.youtube.com');
        expect(songListenLink(_song).queryParameters['q'], 'Raindance Dave');
      },
    );

    test('the card is bright enough to read white text on a dark cover', () {
      const nearlyBlack = Color(0xFF1A1405);

      final bright = HSLColor.fromColor(brightCardColor(nearlyBlack));

      expect(bright.lightness, closeTo(0.62, 0.01));
    });

    test('a grey cover makes a grey card, not a pink one', () {
      final card = HSLColor.fromColor(brightCardColor(const Color(0xFF3A3A3A)));

      expect(card.saturation, lessThan(0.08));
    });

    test('the black card ignores the cover colour', () {
      final gradient = shareCardBackground(
        ShareCardStyle.black,
        Colors.red,
      ) as LinearGradient;

      expect(gradient.colors.toSet(), {const Color(0xFF121212)});
    });
  });

  test('total durations read like Spotify', () {
    expect(formatTotalDuration(const Duration(minutes: 130)), '2 h 10 min');
    expect(formatTotalDuration(const Duration(hours: 1)), '1 h');
    expect(
      formatTotalDuration(const Duration(minutes: 34, seconds: 5)),
      '34 min',
    );
    expect(formatTotalDuration(const Duration(seconds: 45)), '45 sec');
  });

  testWidgets('the player ⋯ opens the song menu with player options', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const NowPlayingPage(),
      size: const Size(400, 860),
    );

    await tester.tap(find.byTooltip('More options'));
    await settleScreen(tester);

    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Lyrics · On'), findsOneWidget);
    expect(find.text('Go to queue'), findsOneWidget);
    expect(find.text('Remove from this playlist'), findsNothing);
  });
}
