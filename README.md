<img width="256" height="256" alt="app_icon_256" src="https://github.com/user-attachments/assets/1fdf3e85-df54-4b52-98fe-6af64a2a7737" />


# Yomi

personal music streaming setup flutter client for a self-hosted
[Navidrome][1] server and small Go service that accepts uploads.

```
app/      Flutter client (Subsonic API, offline downloads, lyrics, home/away routing)
server/   yomi-upload — Go service that authenticates against Navidrome and stores audio files
release/  built APKs for sideloading (not tracked)
```

## Client (`app/`)

```bash
cd app
flutter pub get
flutter test
flutter run                     # debug on a connected device
flutter build apk --release     # -> build/app/outputs/flutter-apk/app-release.apk
flutter run -d macos             # native Mac app
```

Sign in with the server address, username and password. An optional second address is used
on the home Wi-Fi; if it stops answering Yomi scans the local network and updates it. The
Connection doctor in Settings tests every saved address and lets you add backups.

Build the Mac app and ZIP with `./app/scripts/build_macos.sh` from the repository root.
See [client instructions](app/README.md) for server setup and Mac keyboard controls.

## Upload service (`server/`)

```bash
cd server
go test ./...
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -o dist/yomi-upload .
```

Configured through environment variables: `YOMI_LISTEN`, `YOMI_NAVIDROME`, `YOMI_MUSIC`,
`YOMI_MAX_FILE_MB`.

## Optional music assistant

Ask Yomi uses `YOMI_LLM_KEY` (with optional `YOMI_LLM_URL` and `YOMI_LLM_MODEL`).
Its chat endpoint can search Navidrome's artists, albums and songs, then retrieve an
artist's tracks before making recommendations. It uses the signed-in listener's
credentials against `YOMI_NAVIDROME`; credentials and file paths are never sent to
the model. Lookups are read-only, paginated and limited to six per chat within the
existing timeout. The model requests tools through the existing JSON response mode.
Library errors are reported separately from empty results.

Deploy the updated Go service to enable catalog lookup; the app's chat API is unchanged.
The separate Discover feature still suggests outside music from the taste summary.

[1]:	https://www.navidrome.org/
