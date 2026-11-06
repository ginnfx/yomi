import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/search_index.dart';
import '../core/youtube/youtube_fetcher.dart';
import '../core/youtube/yt_dlp.dart';

/// How long getting a newer yt-dlp may hold up the first search.
const Duration _updateWait = Duration(seconds: 45);

enum YoutubeStep { searching, downloading, ready, failed }

/// Where fetching one song from YouTube has got to.
@immutable
class YoutubeState {
  const YoutubeState(this.step, {this.progress, this.error});

  final YoutubeStep step;
  final double? progress;
  final String? error;

  bool get isBusy =>
      step == YoutubeStep.searching || step == YoutubeStep.downloading;
}

/// Plays songs the library doesn't have straight from YouTube, on this device, and
/// saves them into the library on request.
class YoutubeController extends ChangeNotifier {
  YoutubeController({
    required this.fetcher,
    required this.saveDir,
    required this.startPlaying,
    required this.upload,
    this.onSaved,
  });

  final YoutubeFetcher fetcher;

  /// Where saved songs wait for the upload queue.
  final Directory saveDir;
  final Future<void> Function(Song song, File file) startPlaying;
  final Future<void> Function(String path) upload;

  /// Called after a song went to the upload queue, to close requests for it.
  final Future<void> Function(String artist, String title)? onSaved;

  final Map<String, YoutubeState> _states = {};
  final Map<String, File> _files = {};
  final Map<String, ({Song song, File file})> _played = {};
  final Set<String> _saved = {};
  Future<void>? _updating;

  bool get isAvailable => fetcher.isAvailable;

  YoutubeState? stateFor(String artist, String title) =>
      _states[_key(artist, title)];

  bool isSaved(Song song) => _saved.contains(song.id);

  String _key(String artist, String title) =>
      '${normalizeForSearch(artist)}|${normalizeForSearch(title)}';

  /// YouTube changes often and the bundled yt-dlp ages, so the first fetch of each
  /// session gets the newest one. A failed update still lets the old one try.
  Future<void> _ensureFresh() => _updating ??= fetcher.ytDlp
      .update()
      .timeout(_updateWait)
      .catchError((Object error) => debugPrint('yt-dlp update: $error'));

  /// Finds, downloads and plays the song. False, with the state's error set, if it
  /// couldn't.
  Future<bool> play({
    required String artist,
    required String title,
    int? durationSeconds,
    bool wantExplicit = false,
  }) async {
    final key = _key(artist, title);
    if (_states[key]?.isBusy ?? false) return false;
    // Played before: the file is still here, so skip the search and download.
    final earlier = _played[key];
    if (earlier != null && earlier.file.existsSync()) {
      _set(key, const YoutubeState(YoutubeStep.ready));
      await startPlaying(earlier.song, earlier.file);
      return true;
    }
    _set(key, const YoutubeState(YoutubeStep.searching));
    try {
      await _ensureFresh();
      final found = await fetcher.find(
        artist: artist,
        title: title,
        durationSeconds: durationSeconds,
        wantExplicit: wantExplicit,
      );
      if (found.isEmpty) {
        _set(
          key,
          const YoutubeState(YoutubeStep.failed, error: 'Not found on YouTube'),
        );
        return false;
      }
      final video = found.first;
      _set(key, const YoutubeState(YoutubeStep.downloading, progress: 0));
      final file = await fetcher.download(
        video,
        onProgress: (fraction) => _set(
          key,
          YoutubeState(YoutubeStep.downloading, progress: fraction),
        ),
      );
      final song = Song(
        id: '$kYoutubeIdPrefix${video.id}',
        title: title,
        artist: artist,
        album: 'From YouTube',
        durationSeconds: video.durationSeconds ?? durationSeconds ?? 0,
      );
      _files[song.id] = file;
      _played[key] = (song: song, file: file);
      _set(key, const YoutubeState(YoutubeStep.ready));
      await startPlaying(song, file);
      return true;
    } on Exception catch (error) {
      debugPrint('YouTube fetch failed: $error');
      final reason = error is YtDlpException ? ' (${error.message})' : '';
      _set(
        key,
        YoutubeState(
          YoutubeStep.failed,
          error: "Couldn't get it from YouTube$reason. Request it instead.",
        ),
      );
      return false;
    }
  }

  /// Puts a song played from YouTube into the library through the upload queue.
  Future<bool> save(Song song) async {
    final file = _files[song.id];
    if (!song.isFromYoutube || file == null || !file.existsSync()) return false;
    try {
      await saveDir.create(recursive: true);
      final target = File(
        '${saveDir.path}/${libraryFileName(artist: song.artist, title: song.title)}',
      );
      await file.copy(target.path);
      await upload(target.path);
      _saved.add(song.id);
      notifyListeners();
      await onSaved?.call(song.artist, song.title);
      return true;
    } on Exception catch (error) {
      debugPrint('Could not save a YouTube song: $error');
      return false;
    }
  }

  void _set(String key, YoutubeState state) {
    _states[key] = state;
    notifyListeners();
  }
}
