import 'package:flutter/foundation.dart';

import 'core/youtube/youtube_fetcher.dart';
import 'state/player_controller.dart';
import 'state/session.dart';

// Debug-only conveniences, set with --dart-define at build time. They do nothing in release builds.
const String _devServer = String.fromEnvironment('YOMI_SERVER');
const String _devUser = String.fromEnvironment('YOMI_USER');
const String _devPassword = String.fromEnvironment('YOMI_PASSWORD');
const bool _devAutoplay = bool.fromEnvironment('YOMI_AUTOPLAY');

const int _devTab = int.fromEnvironment('YOMI_TAB');
const bool _devNowPlaying = bool.fromEnvironment('YOMI_NOWPLAYING');
const bool _devOpenSettings = bool.fromEnvironment('YOMI_SETTINGS');

/// Whether to open the settings sheet right after launch.
bool get devOpenSettings => kDebugMode && _devOpenSettings;

/// Which tab the shell opens on.
int get devInitialTab => kDebugMode ? _devTab : 0;

/// Whether to open the Now Playing screen right after launch.
bool get devOpenNowPlaying => kDebugMode && _devNowPlaying;

Future<void> runDevHooks(
  SessionController session,
  PlayerController player,
) async {
  if (!kDebugMode) return;
  try {
    if (!session.isSignedIn && _devServer.isNotEmpty) {
      await session.signIn(_devServer, _devUser, _devPassword);
    }
    if (_devAutoplay && session.isSignedIn) {
      await player.playQueue(await session.client.randomSongs(size: 6));
    }
  } on Exception catch (error) {
    debugPrint('dev hook failed: $error');
  }
}

const String _devYoutube = String.fromEnvironment('YOMI_YTDLP_SPIKE');

/// Debug builds started with YOMI_YTDLP_SPIKE="artist - title" search YouTube and
/// download the best match at launch, printing what happened, to check yt-dlp works
/// on a device.
Future<void> runYoutubeSpike(YoutubeFetcher fetcher) async {
  if (!kDebugMode || _devYoutube.isEmpty) return;
  final watch = Stopwatch()..start();
  try {
    await fetcher.ytDlp.update();
    final version = await fetcher.ytDlp.run(['--ignore-config', '--version']);
    debugPrint(
      'YTSPIKE yt-dlp ${version.trim()} after ${watch.elapsedMilliseconds}ms',
    );
  } on Exception catch (error) {
    debugPrint('YTSPIKE update failed: $error');
  }
  var succeeded = 0;
  final songs = _devYoutube.split(';');
  for (final song in songs) {
    final parts = song.trim().split(' - ');
    watch.reset();
    try {
      final found = await fetcher.find(
        artist: parts.length > 1 ? parts.first : '',
        title: parts.last,
      );
      if (found.isEmpty) {
        debugPrint('YTSPIKE nothing found for $song');
        continue;
      }
      final file = await fetcher.download(found.first);
      succeeded++;
      debugPrint(
        'YTSPIKE downloaded ${watch.elapsedMilliseconds}ms: '
        '${found.first.title} ${file.lengthSync()} bytes',
      );
    } on Exception catch (error) {
      debugPrint('YTSPIKE failed after ${watch.elapsedMilliseconds}ms: $error');
    }
  }
  debugPrint('YTSPIKE done: $succeeded/${songs.length}');
}
