import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../search_index.dart';

/// m4a first: every platform's player can open it, and no conversion is needed.
const String kAudioFormat =
    'bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio';

/// Clients that still hand out full audio files when the default one is blocked.
const String kExtractorArgs = 'youtube:player_client=default,android,tv';

/// The largest file a download may produce; a song is a few MB.
const String _maxFileSize = '250M';

/// Song ids for music played straight from YouTube, never sent to the server.
const String kYoutubeIdPrefix = 'yt:';

final RegExp _videoId = RegExp(r'^[A-Za-z0-9_-]{6,20}$');
final RegExp _progress = RegExp(r'^download:\s*([0-9.]+)%');

/// One video found by a search.
@immutable
class YoutubeResult {
  const YoutubeResult({
    required this.id,
    required this.title,
    required this.channel,
    this.durationSeconds,
  });

  final String id;
  final String title;
  final String channel;
  final int? durationSeconds;

  Uri get url => Uri.https('www.youtube.com', '/watch', {'v': id});
}

/// Runs yt-dlp on this device. Desktop runs the official binary; Android runs the
/// copy bundled with youtubedl-android; iPhone answers the same commands with the
/// Swift YouTubeKit extractor (ios/Runner/YtDlpChannel.swift).
abstract class YtDlp {
  bool get isAvailable;

  /// Runs yt-dlp with [args]. Lines are passed to [onLine] as they arrive.
  /// Throws [YtDlpException] when it fails.
  Future<String> run(List<String> args, {void Function(String line)? onLine});

  /// Gets the newest yt-dlp, since YouTube changes often. Failures are not fatal.
  Future<void> update();
}

class YtDlpException implements Exception {
  const YtDlpException(this.message);

  final String message;

  @override
  String toString() => 'YtDlpException: $message';
}

/// A device without yt-dlp.
class UnavailableYtDlp implements YtDlp {
  const UnavailableYtDlp();

  @override
  bool get isAvailable => false;

  @override
  Future<String> run(List<String> args, {void Function(String line)? onLine}) =>
      Future.error(const YtDlpException('YouTube is not available here'));

  @override
  Future<void> update() async {}
}

List<String> searchArgs(String query, {required int count}) => [
  '--ignore-config',
  '--flat-playlist',
  '--dump-json',
  '--no-warnings',
  'ytsearch$count:$query',
];

List<String> downloadArgs(String videoId, String directory) {
  if (!_videoId.hasMatch(videoId)) {
    throw ArgumentError.value(videoId, 'videoId', 'not a YouTube video id');
  }
  return [
    '--ignore-config',
    '-f',
    kAudioFormat,
    '--no-playlist',
    '--extractor-args',
    kExtractorArgs,
    '--max-filesize',
    _maxFileSize,
    '--no-warnings',
    '--newline',
    '--progress-template',
    'download:%(progress._percent_str)s',
    '-o',
    '$directory${Platform.pathSeparator}%(id)s.%(ext)s',
    '--print',
    'after_move:filepath',
    'https://www.youtube.com/watch?v=$videoId',
  ];
}

/// One JSON object per line; anything else (warnings) is skipped.
List<YoutubeResult> parseSearchOutput(String out) {
  final results = <YoutubeResult>[];
  for (final line in const LineSplitter().convert(out)) {
    final text = line.trim();
    if (!text.startsWith('{')) continue;
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) continue;
      final id = json['id'];
      final title = json['title'];
      if (id is! String || title is! String) continue;
      results.add(
        YoutubeResult(
          id: id,
          title: title,
          channel:
              (json['channel'] as String?) ??
              (json['uploader'] as String?) ??
              '',
          durationSeconds: (json['duration'] as num?)?.round(),
        ),
      );
    } on FormatException {
      continue;
    }
  }
  return List.unmodifiable(results);
}

/// 0 to 1 for a progress line, null for anything else.
double? parseProgress(String line) {
  final match = _progress.firstMatch(line.trim());
  if (match == null) return null;
  final percent = double.tryParse(match.group(1)!);
  return percent == null ? null : (percent / 100).clamp(0, 1);
}

/// Words that mean a different recording than the one asked for.
const List<String> _otherVersions = [
  'live',
  'cover',
  'remix',
  'karaoke',
  'instrumental',
  'slowed',
  'sped up',
  'nightcore',
  '8d',
  'reverb',
  'acoustic',
  'lyrics',
  'loop',
  'hour',
  'hours',
  'mix',
];

/// Longer than this is a loop, a compilation or a full album, not one song.
const int _longestSongSeconds = 15 * 60;

/// Best match first: title words, the artist's own channel, no other versions, and a
/// length close to the expected one.
List<YoutubeResult> rankResults(
  List<YoutubeResult> results, {
  required String artist,
  required String title,
  int? durationSeconds,
  bool wantExplicit = false,
}) {
  final wanted = normalizeForSearch(title);
  final wantedWords = wanted.split(' ').where((w) => w.isNotEmpty).toSet();
  final artistName = normalizeForSearch(artist);
  double score(YoutubeResult result) {
    final name = normalizeForSearch(result.title);
    final channel = normalizeForSearch(result.channel);
    var total = 0.0;
    final words = name.split(' ').toSet();
    if (wantedWords.isNotEmpty) {
      total +=
          4 * wantedWords.where(words.contains).length / wantedWords.length;
    }
    if (artistName.isNotEmpty &&
        (channel.contains(artistName) || name.contains(artistName))) {
      total += 2;
    }
    if (channel.endsWith('topic') || name.contains('official audio')) {
      total += 1.5;
    }
    for (final word in _otherVersions) {
      if (_hasWord(name, word) && !_hasWord(wanted, word)) total -= 3;
    }
    if (_hasWord(name, 'clean')) total += wantExplicit ? -3 : 0;
    if (_hasWord(name, 'explicit')) total += wantExplicit ? 2 : 0;
    final expected = durationSeconds;
    final actual = result.durationSeconds;
    if (actual != null && actual > _longestSongSeconds) total -= 5;
    if (expected != null && expected > 0 && actual != null) {
      final off = (actual - expected).abs() / expected;
      total += off < 0.05 ? 1.5 : (off < 0.15 ? 0.5 : -2);
    }
    return total;
  }

  final scored = [for (final result in results) (result, score(result))]
    ..sort((a, b) => b.$2.compareTo(a.$2));
  return List.unmodifiable([for (final (result, _) in scored) result]);
}

bool _hasWord(String text, String word) =>
    RegExp('(^| )${RegExp.escape(word)}( |\$)').hasMatch(text);

/// "Title - Artist.m4a": the server keeps the name, and the app reads untagged files
/// named this way as title and artist.
String libraryFileName({required String artist, required String title}) {
  String clean(String text) => text
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return '${clean(title)} - ${clean(artist)}.m4a';
}
