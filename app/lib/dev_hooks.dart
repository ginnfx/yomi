import 'package:flutter/foundation.dart';

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
