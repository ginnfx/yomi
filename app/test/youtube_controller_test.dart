import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/youtube/youtube_fetcher.dart';
import 'package:yomi/core/youtube/yt_dlp.dart';
import 'package:yomi/state/youtube_controller.dart';

/// Answers searches with two videos and "downloads" by writing a small file.
class _FakeYtDlp implements YtDlp {
  _FakeYtDlp(this.cache);

  final Directory cache;
  final calls = <List<String>>[];
  int updates = 0;
  bool failDownloads = false;

  @override
  bool get isAvailable => true;

  @override
  Future<void> update() async => updates++;

  @override
  Future<String> run(
    List<String> args, {
    void Function(String line)? onLine,
  }) async {
    calls.add(args);
    if (args.last.startsWith('ytsearch')) {
      return [
        jsonEncode({
          'id': 'live0000001',
          'title': 'Blue Hour (Live)',
          'channel': 'Mira',
          'duration': 260,
        }),
        jsonEncode({
          'id': 'real0000001',
          'title': 'Mira - Blue Hour (Official Audio)',
          'channel': 'Mira',
          'duration': 200,
        }),
      ].join('\n');
    }
    if (failDownloads) throw const YtDlpException('HTTP Error 403: Forbidden');
    final id = Uri.parse(args.last).queryParameters['v']!;
    final file = File('${cache.path}/$id.m4a')..writeAsStringSync('audio');
    onLine?.call('download: 50.0%');
    onLine?.call(file.path);
    return file.path;
  }
}

void main() {
  late Directory dir;
  late _FakeYtDlp ytDlp;
  late List<(Song, File)> played;
  late List<String> uploaded;
  late List<String> saved;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yomi_youtube');
    ytDlp = _FakeYtDlp(Directory('${dir.path}/cache'));
    played = [];
    uploaded = [];
    saved = [];
  });
  tearDown(() => dir.delete(recursive: true));

  YoutubeController controller() => YoutubeController(
    fetcher: YoutubeFetcher(
      ytDlp: ytDlp,
      cacheDir: Directory('${dir.path}/cache'),
    ),
    saveDir: Directory('${dir.path}/save'),
    startPlaying: (song, file) async => played.add((song, file)),
    upload: (path) async => uploaded.add(path),
    onSaved: (artist, title) async => saved.add('$artist|$title'),
  );

  test(
    'plays the best match as a YouTube song with the asked-for names',
    () async {
      // Arrange
      final youtube = controller();

      // Act
      final isPlaying = await youtube.play(artist: 'Mira', title: 'Blue Hour');

      // Assert
      expect(isPlaying, isTrue);
      final (song, file) = played.single;
      expect(song.id, 'yt:real0000001');
      expect(song.isFromYoutube, isTrue);
      expect(song.title, 'Blue Hour');
      expect(song.artist, 'Mira');
      expect(file.existsSync(), isTrue);
    },
  );

  test('gets the newest yt-dlp once before the first search', () async {
    // Arrange
    final youtube = controller();

    // Act
    await youtube.play(artist: 'Mira', title: 'Blue Hour');
    await youtube.play(artist: 'Mira', title: 'Other');

    // Assert
    expect(ytDlp.updates, 1);
  });

  test('a failed download says why and plays nothing', () async {
    // Arrange
    ytDlp.failDownloads = true;
    final youtube = controller();

    // Act
    final isPlaying = await youtube.play(artist: 'Mira', title: 'Blue Hour');

    // Assert
    expect(isPlaying, isFalse);
    expect(played, isEmpty);
    expect(
      youtube.stateFor('Mira', 'Blue Hour')?.error,
      contains("Couldn't get it from YouTube"),
    );
  });

  test('saving copies the song as "Title - Artist.m4a", uploads it and closes the request', () async {
    // Arrange
    final youtube = controller();
    await youtube.play(artist: 'Mira', title: 'Blue Hour');
    final song = played.single.$1;

    // Act
    final isSaved = await youtube.save(song);

    // Assert
    expect(isSaved, isTrue);
    expect(uploaded.single, endsWith('Blue Hour - Mira.m4a'));
    expect(File(uploaded.single).existsSync(), isTrue);
    expect(saved, ['Mira|Blue Hour']);
    expect(youtube.isSaved(song), isTrue);
  });

  test(
    'a song that did not come from YouTube cannot be saved this way',
    () async {
      // Arrange
      final youtube = controller();
      const librarySong = Song(
        id: 's1',
        title: 'T',
        artist: 'A',
        album: 'X',
        durationSeconds: 1,
      );

      // Act
      final isSaved = await youtube.save(librarySong);

      // Assert
      expect(isSaved, isFalse);
      expect(uploaded, isEmpty);
    },
  );
}
