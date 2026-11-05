import 'package:flutter/foundation.dart';

import '../search_index.dart';
import 'imported_playlist.dart';

/// A song an imported playlist has that the library doesn't, and where it came from.
@immutable
class MissingSong {
  const MissingSong({
    required this.title,
    required this.artist,
    required this.playlists,
  });

  final String title;
  final String artist;
  final List<String> playlists;
}

/// Songs to add so imported playlists are complete, once each, in playlist order.
List<MissingSong> missingFromImports(List<ImportedPlaylist> playlists) {
  final order = <String>[];
  final first = <String, ImportEntry>{};
  final sources = <String, List<String>>{};
  for (final playlist in playlists) {
    for (final entry in playlist.entries) {
      if (entry.songId != null) continue;
      final key =
          '${normalizeForSearch(entry.artist)}|${normalizeForSearch(entry.title)}';
      if (!first.containsKey(key)) {
        order.add(key);
        first[key] = entry;
      }
      final from = sources.putIfAbsent(key, () => []);
      if (!from.contains(playlist.name)) from.add(playlist.name);
    }
  }
  return List.unmodifiable([
    for (final key in order)
      MissingSong(
        title: first[key]!.title,
        artist: first[key]!.artist,
        playlists: List.unmodifiable(sources[key]!),
      ),
  ]);
}
