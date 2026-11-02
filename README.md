# Yomi

A personal music streaming setup: a Flutter client (iOS and Android) for a self-hosted
[Navidrome](https://www.navidrome.org/) server, plus a small Go service that accepts uploads.

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
```

Sign in with the server address, username and password. An optional second address is used
on the home Wi-Fi; if it stops answering Yomi scans the local network and updates it. The
Connection doctor in Settings tests every saved address and lets you add backups.

## Upload service (`server/`)

```bash
cd server
go test ./...
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -o dist/yomi-upload .
```

Configured through environment variables: `YOMI_LISTEN`, `YOMI_NAVIDROME`, `YOMI_MUSIC`,
`YOMI_MAX_FILE_MB`.
