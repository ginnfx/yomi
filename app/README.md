# Yomi client

One Flutter app for iOS, Android, and macOS. The Mac version uses the same
Subsonic/Navidrome client and Yomi upload service as the mobile app.

## macOS

Requires macOS 12 or later. To develop, install Flutter and Xcode, then:

```sh
flutter pub get
flutter run -d macos
```

Build the release app and a ZIP archive from the repository root:

```sh
./app/scripts/build_macos.sh
open release/Yomi.app
```

The output is `release/Yomi.app` and `release/Yomi-macOS.zip`. This is a local,
ad-hoc signed build. Distribution outside your own Mac requires your Apple
Developer signing identity and notarization.

### Connect to the existing server

The Mac sign-in screen starts with the addresses referenced in the source:

- Away/Tailscale: `http://100.88.180.104:4533`
- Home network: `http://192.168.1.18:4533`

Sign in using only the same username and password as on iOS. Server addresses
are preconfigured on every platform and editable under Advanced connection
settings if the server has moved. The Tailscale address requires this Mac to have access to the same
tailnet; the home address requires access to that LAN. Uploads use the same
server host on port 4534. Home/away routing, backup addresses, and Connection
doctor remain available in Settings. Credentials are stored in the Mac login
Keychain; downloads and preferences are local to this Mac.

Override the initial addresses when building for another server (no password
needs to be embedded):

```sh
./app/scripts/build_macos.sh \
  --dart-define=YOMI_SERVER=http://your-server:4533 \
  --dart-define=YOMI_HOME_SERVER=http://your-home-server:4533
```

### Continue listening on another device

Sign in to the same server account on both devices. Listening sync is on by
default and can be disabled in Settings → Listening across devices. The account
already shares server playlists and favorites.

Yomi saves the queue, current song, and position while playing (roughly every
five seconds), on pause/seek, and when the app goes into the background. Open
Yomi on the other device and tap **Continue here**, or press Play on the
restored player. The previous device pauses when it detects the handoff,
usually within five seconds while connected and running. Playback does not
start just because you open the app. Downloads and appearance remain local.

Both the Mac and iPhone need this updated client. Older Yomi iOS builds do not
publish or restore listening positions. Build/install the updated iOS app using
the existing Xcode signing setup (`./app/scripts/install_ios.sh <device-id>`
from the repository root). This uses an in-place installation to preserve app data.
Both devices must reach the music server; handoff is not available offline.
The shared position can trail live playback by a few seconds, and iOS may delay
sync when it suspends background execution.

The implementation uses Navidrome's existing per-user `getPlayQueue` and
`savePlayQueue` endpoints; no new account service or server deployment is needed.

### Desktop behavior

Wide windows use a sidebar, compact music shortcuts, and a persistent player
with seeking and volume controls; narrow windows use the compact tab bar. Streaming,
queue, shuffle/repeat, search, artists/albums, favorites, playlists, lyrics,
downloads, caching, uploads, profiles, themes, and connection settings share
the mobile implementation. Uploads and profile pictures use the Mac file picker.
The existing audio service provides system Now Playing integration.

| Shortcut | Action |
| --- | --- |
| Space | Play/pause, outside text fields |
| Command-P | Play/pause |
| Command-Right / Command-Left | Next / previous song |
| Command-N | Now Playing, including lyrics and queue |
| Command-, | Settings |

On the Mac, cached songs persist in Application Support across restarts. A
handoff prefetches its current song and the next three on Wi-Fi or Ethernet.
During streaming, warming starts once the player has a ten-second buffer rather
than waiting for the entire song. Downloads stay separate from the automatic
cache. Settings lets you toggle caching and preloading independently and choose
the cache size. Clearing or evicting a song lets it be cached again on replay.
A small offline icon in the desktop player confirms that the song is available
locally. Pending warm-ups follow the current queue and run one at a time.

The menu bar also offers editing, playback, shuffle, repeat, and window commands.
Closing the last window quits the app; minimizing keeps playback running.

## Releasing

Tagging `vX.Y.Z` runs the tests, builds the signed APK and Mac app, and publishes
them as a GitHub release. Android and Mac users then see an update banner.

```sh
git tag v1.0.2 && git push origin v1.0.2
```

### Android signing

Installed copies only accept updates signed with the same key, so release builds
refuse to run without `android/key.properties` (gitignored):

```properties
storeFile=/absolute/path/to/your-release.jks
storePassword=...
keyAlias=yomi
keyPassword=...
```

`scripts/build_android.sh X.Y.Z` builds locally and checks the APK against the
public fingerprint in `android/release-cert.sha256`. To publish from your own fork,
replace that file with your key's fingerprint.

CI reads two secrets from a GitHub environment named `release`:
`YOMI_KEYSTORE_BASE64` (the `.jks`, base64 encoded) and `YOMI_KEYSTORE_PASSWORD`.
Limit that environment to `v*` tags, so only release tags can read the key.

## Checks

```sh
flutter analyze --no-fatal-infos
flutter test
flutter build macos --release
```

Live playback and uploads additionally need a reachable server and a valid account.
