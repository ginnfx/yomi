import '../models.dart';
import '../subsonic_client.dart';

const int _pageSize = 500;

/// How close two durations must be to count as the same recording.
const int kLikelyDuplicateSeconds = 2;

/// The library's artist, title and duration, for spotting probable duplicates that
/// differ in bytes, such as the same song in another format.
class LibrarySnapshot {
  LibrarySnapshot(Iterable<Song> songs) {
    for (final song in songs) {
      add(song.artist, song.title, song.durationSeconds);
    }
  }

  static Future<LibrarySnapshot> load(SubsonicClient client) async {
    final songs = <Song>[];
    while (true) {
      final page = await client.songs(offset: songs.length, count: _pageSize);
      songs.addAll(page);
      if (page.length < _pageSize) return LibrarySnapshot(songs);
    }
  }

  final Map<String, List<int>> _durations = {};

  static String _keyOf(String artist, String title) =>
      '${_normalize(artist)}|${_normalize(title)}';

  static String _normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    '',
  );

  void add(String artist, String title, int durationSeconds) {
    _durations
        .putIfAbsent(_keyOf(artist, title), () => [])
        .add(durationSeconds);
  }

  /// Untagged files and unknown lengths never match: a false "new" only uploads
  /// a song, while a false "duplicate" would quietly leave it behind.
  bool hasLikelyMatch(String? artist, String? title, int durationSeconds) {
    if (artist == null || title == null || durationSeconds <= 0) return false;
    if (_normalize(artist).isEmpty || _normalize(title).isEmpty) return false;
    final known = _durations[_keyOf(artist, title)];
    if (known == null) return false;
    return known.any(
      (duration) =>
          duration > 0 &&
          (duration - durationSeconds).abs() <= kLikelyDuplicateSeconds,
    );
  }
}
