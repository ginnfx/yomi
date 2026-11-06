import 'dart:io';

import 'channel_yt_dlp.dart';
import 'process_yt_dlp.dart';
import 'yt_dlp.dart';

const int _resultsPerSearch = 5;

/// The yt-dlp this device can run.
YtDlp ytDlpForThisDevice(Directory supportDir) {
  if (Platform.isAndroid) return ChannelYtDlp();
  final binary = ProcessYtDlp.binaryFor(Platform.operatingSystem);
  if (binary == null) return const UnavailableYtDlp();
  // The Mac app is sandboxed, which only lets it run programs inside its own bundle.
  if (Platform.isMacOS) {
    final helper = File(
      '${File(Platform.resolvedExecutable).parent.parent.path}/Resources/yt-dlp/$binary',
    );
    return helper.existsSync()
        ? BundledYtDlp(helper)
        : const UnavailableYtDlp();
  }
  return ProcessYtDlp(
    directory: Directory('${supportDir.path}/yt-dlp'),
    binaryName: binary,
  );
}

/// Finds a song on YouTube and saves its audio in a cache folder.
class YoutubeFetcher {
  YoutubeFetcher({required this.ytDlp, required this.cacheDir});

  final YtDlp ytDlp;
  final Directory cacheDir;

  bool get isAvailable => ytDlp.isAvailable;

  /// Videos that may be the song, best match first.
  Future<List<YoutubeResult>> find({
    required String artist,
    required String title,
    int? durationSeconds,
    bool wantExplicit = false,
  }) async {
    final query = [
      if (artist.isNotEmpty) '$artist -',
      title,
      if (wantExplicit) 'explicit',
    ].join(' ');
    final out = await ytDlp.run(searchArgs(query, count: _resultsPerSearch));
    return rankResults(
      parseSearchOutput(out),
      artist: artist,
      title: title,
      durationSeconds: durationSeconds,
      wantExplicit: wantExplicit,
    );
  }

  /// The audio file for [video], downloaded unless it's already cached.
  Future<File> download(
    YoutubeResult video, {
    void Function(double fraction)? onProgress,
  }) async {
    final cached = _cached(video.id);
    if (cached != null) return cached;
    await cacheDir.create(recursive: true);
    String? path;
    await ytDlp.run(
      downloadArgs(video.id, cacheDir.path),
      onLine: (line) {
        final progress = parseProgress(line);
        if (progress != null) {
          onProgress?.call(progress);
        } else if (line.trim().startsWith(cacheDir.path)) {
          path = line.trim();
        }
      },
    );
    final file = path == null ? _cached(video.id) : File(path!);
    if (file == null || !file.existsSync()) {
      throw const YtDlpException('yt-dlp finished without a file');
    }
    return file;
  }

  File? _cached(String videoId) {
    if (!cacheDir.existsSync()) return null;
    for (final entity in cacheDir.listSync()) {
      final name = entity.uri.pathSegments.last;
      if (entity is File &&
          name.startsWith('$videoId.') &&
          !name.endsWith('.part') &&
          !name.endsWith('.ytdl')) {
        return entity;
      }
    }
    return null;
  }
}
