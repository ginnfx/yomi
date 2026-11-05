import '../listening/play_history.dart';
import '../models.dart';

/// How many recent songs to offer for sending.
const int kRecentToSend = 20;

/// Songs ready to send without searching: what's playing, then recent plays, newest first.
List<Song> recentToSend({
  required List<PlayEvent> events,
  required Song? Function(String songId) songFor,
  Song? nowPlaying,
  int max = kRecentToSend,
}) {
  final newestFirst = [...events]..sort((a, b) => b.at.compareTo(a.at));
  final seen = <String>{};
  final songs = <Song>[];
  void add(Song? song) {
    if (song != null && songs.length < max && seen.add(song.id)) {
      songs.add(song);
    }
  }

  add(nowPlaying);
  for (final event in newestFirst) {
    add(songFor(event.songId));
  }
  return List.unmodifiable(songs);
}
