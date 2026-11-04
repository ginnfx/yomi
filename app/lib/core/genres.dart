import 'package:flutter/foundation.dart';

import 'models.dart';
import 'subsonic_client.dart';

/// Tags mean the same thing under many spellings. Keys are normalised (see [_key]).
const Map<String, String> _canonicalNames = {
  'hiphop': 'Hip-Hop',
  'rap': 'Hip-Hop',
  'hiphoprap': 'Hip-Hop',
  'raphiphop': 'Hip-Hop',
  'trap': 'Hip-Hop',
  'rnb': 'R&B',
  'randb': 'R&B',
  'rb': 'R&B',
  'rhythmandblues': 'R&B',
  'soulrnb': 'R&B',
  'electronic': 'Electronic',
  'electronica': 'Electronic',
  'edm': 'Electronic',
  'dance': 'Electronic',
  'danceelectronic': 'Electronic',
  'electronicdance': 'Electronic',
  'drumandbass': 'Drum & Bass',
  'drumnbass': 'Drum & Bass',
  'dnb': 'Drum & Bass',
  'alternative': 'Alternative',
  'alt': 'Alternative',
  'altrock': 'Alternative',
  'alternativerock': 'Alternative',
  'indie': 'Indie',
  'indierock': 'Indie',
  'indiepop': 'Indie',
  'rocknroll': 'Rock',
  'rockandroll': 'Rock',
  'classicrock': 'Rock',
  'hardrock': 'Rock',
  'pop': 'Pop',
  'poprock': 'Pop',
  'synthpop': 'Pop',
  'country': 'Country',
  'soundtrack': 'Soundtrack',
  'ost': 'Soundtrack',
  'filmscore': 'Soundtrack',
  'lofi': 'Lo-Fi',
  'lofihiphop': 'Lo-Fi',
  'kpop': 'K-Pop',
  'jpop': 'J-Pop',
};

String _key(String genre) => genre
    .toLowerCase()
    .replaceAll('&', 'and')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// The display name a raw tag belongs under. Unrecognised tags keep their own spelling.
String canonicalGenre(String raw) {
  final trimmed = raw.trim();
  return _canonicalNames[_key(trimmed)] ?? trimmed;
}

/// One filter chip: a name and every raw tag that means it.
@immutable
class GenreGroup {
  const GenreGroup(this.name, this.variants, this.songCount);

  final String name;
  final List<String> variants;
  final int songCount;
}

/// Merges the server's genres into groups, largest first. Case differences merge too.
List<GenreGroup> groupGenres(Iterable<Genre> genres) {
  final variants = <String, List<String>>{};
  final counts = <String, int>{};
  final names = <String, String>{};
  for (final genre in genres) {
    final raw = genre.name.trim();
    if (raw.isEmpty) continue;
    final name = canonicalGenre(raw);
    final key = _key(name);
    if (key.isEmpty) continue;
    names.putIfAbsent(key, () => name);
    variants.putIfAbsent(key, () => []).add(genre.name);
    counts[key] = (counts[key] ?? 0) + genre.songCount;
  }
  final groups = [
    for (final key in names.keys)
      GenreGroup(names[key]!, List.unmodifiable(variants[key]!), counts[key]!),
  ]..sort((a, b) => b.songCount.compareTo(a.songCount));
  return List.unmodifiable(groups);
}

/// Whether [song] falls under any of [selected]. No selection means everything.
bool songMatchesGenres(Song song, Set<String> selected) {
  if (selected.isEmpty) return true;
  final genre = song.genre;
  return genre != null && selected.contains(canonicalGenre(genre));
}

/// Pages through several raw genres as one list, without repeating songs tagged twice.
class GenrePager {
  GenrePager(this.client, Iterable<GenreGroup> groups, {this.pageSize = 100})
    : _pending = [for (final group in groups) ...group.variants];

  final SubsonicClient client;
  final int pageSize;
  final List<String> _pending;
  final Set<String> _seen = {};
  int _offset = 0;

  bool get isDone => _pending.isEmpty;

  Future<List<Song>> nextPage() async {
    final found = <Song>[];
    while (found.length < pageSize && _pending.isNotEmpty) {
      final page = await client.songsByGenre(
        _pending.first,
        offset: _offset,
        count: pageSize,
      );
      final fresh = page.where((song) => _seen.add(song.id)).toList();
      found.addAll(fresh);
      // A page of nothing new means a server ignoring the offset; don't loop on it.
      if (page.length < pageSize || fresh.isEmpty) {
        _pending.removeAt(0);
        _offset = 0;
      } else {
        _offset += pageSize;
      }
    }
    return List.unmodifiable(found);
  }
}
