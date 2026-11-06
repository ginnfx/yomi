import 'package:flutter/foundation.dart';

/// Reads a JSON list under [key], tolerating a missing key.
List<Map<String, dynamic>> jsonList(Map<String, dynamic>? json, String key) {
  final value = json?[key];
  if (value is List) {
    return value.whereType<Map<String, dynamic>>().toList(growable: false);
  }
  return const [];
}

@immutable
class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    this.albumId,
    this.coverArtId,
    this.track,
    this.isStarred = false,
    this.genre,
    this.playCount = 0,
    this.addedAt,
    this.explicitStatus,
  });

  /// Untagged files arrive with the file name as the title and no artist. Files named
  /// "Title - Artist" are split so they show up properly.
  factory Song.fromJson(Map<String, dynamic> json) {
    final rawTitle = (json['title'] as String?)?.trim() ?? '';
    final rawArtist = (json['artist'] as String?)?.trim() ?? '';
    final isUntagged =
        rawArtist.isEmpty ||
        rawArtist.toLowerCase() == '[unknown artist]' ||
        rawArtist.toLowerCase() == 'unknown artist';
    final split = isUntagged
        ? RegExp(r'^(.+?)\s+-\s+(.+)$').firstMatch(rawTitle)
        : null;
    return Song._(
      json,
      split?.group(1)?.trim() ??
          (rawTitle.isEmpty ? 'Unknown title' : rawTitle),
      split?.group(2)?.trim() ?? (isUntagged ? 'Unknown artist' : rawArtist),
    );
  }

  factory Song._(Map<String, dynamic> json, String title, String artist) =>
      Song(
        id: json['id'].toString(),
        title: title,
        artist: artist,
        album: (json['album'] as String?) ?? 'Unknown album',
        durationSeconds: (json['duration'] as num?)?.toInt() ?? 0,
        albumId: json['albumId']?.toString(),
        coverArtId: json['coverArt']?.toString(),
        track: (json['track'] as num?)?.toInt(),
        isStarred: json['starred'] != null,
        genre: (json['genre'] as String?)?.trim(),
        playCount: (json['playCount'] as num?)?.toInt() ?? 0,
        addedAt: DateTime.tryParse(json['created']?.toString() ?? ''),
        explicitStatus: switch (json['explicitStatus']) {
          final String status when status.isNotEmpty => status,
          _ => null,
        },
      );

  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationSeconds;
  final String? albumId;
  final String? coverArtId;
  final int? track;
  final bool isStarred;

  final String? genre;

  /// How many times the server has counted this as played, across all devices.
  final int playCount;

  /// When the song joined the library, if the server said.
  final DateTime? addedAt;

  /// OpenSubsonic's "explicit" or "clean" when the file is tagged, else null.
  final String? explicitStatus;

  /// A censored version: someone may want the explicit one instead.
  bool get isClean => explicitStatus == 'clean';

  /// Played straight from YouTube: not in the library, so never sent to the server.
  bool get isFromYoutube => id.startsWith('yt:');

  Duration get duration => Duration(seconds: durationSeconds);

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'duration': durationSeconds,
    'albumId': albumId,
    'coverArt': coverArtId,
    'track': track,
    'starred': isStarred ? 'yes' : null,
    'genre': genre,
    'playCount': playCount,
    'created': addedAt?.toIso8601String(),
    'explicitStatus': explicitStatus,
  };

  Song copyWith({bool? isStarred}) => Song(
    id: id,
    title: title,
    artist: artist,
    album: album,
    durationSeconds: durationSeconds,
    albumId: albumId,
    coverArtId: coverArtId,
    track: track,
    isStarred: isStarred ?? this.isStarred,
    genre: genre,
    playCount: playCount,
    addedAt: addedAt,
    explicitStatus: explicitStatus,
  );
}

@immutable
class Album {
  const Album({
    required this.id,
    required this.name,
    required this.artist,
    required this.songCount,
    this.coverArtId,
    this.year,
  });

  factory Album.fromJson(Map<String, dynamic> json) => Album(
    id: json['id'].toString(),
    name:
        (json['name'] as String?) ??
        (json['title'] as String?) ??
        'Unknown album',
    artist: (json['artist'] as String?) ?? 'Unknown artist',
    songCount: (json['songCount'] as num?)?.toInt() ?? 0,
    coverArtId: json['coverArt']?.toString(),
    year: (json['year'] as num?)?.toInt(),
  );

  final String id;
  final String name;
  final String artist;
  final int songCount;
  final String? coverArtId;
  final int? year;
}

@immutable
class Artist {
  const Artist({
    required this.id,
    required this.name,
    required this.albumCount,
    this.coverArtId,
  });

  factory Artist.fromJson(Map<String, dynamic> json) => Artist(
    id: json['id'].toString(),
    name: (json['name'] as String?) ?? 'Unknown artist',
    albumCount: (json['albumCount'] as num?)?.toInt() ?? 0,
    coverArtId: json['coverArt']?.toString(),
  );

  final String id;
  final String name;
  final int albumCount;
  final String? coverArtId;
}

@immutable
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.songCount,
    required this.durationSeconds,
    this.owner,
    this.coverArtId,
  });

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'].toString(),
    name: (json['name'] as String?) ?? 'Untitled playlist',
    songCount: (json['songCount'] as num?)?.toInt() ?? 0,
    durationSeconds: (json['duration'] as num?)?.toInt() ?? 0,
    owner: json['owner'] as String?,
    coverArtId: json['coverArt']?.toString(),
  );

  final String id;
  final String name;
  final int songCount;
  final int durationSeconds;
  final String? owner;
  final String? coverArtId;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'songCount': songCount,
    'duration': durationSeconds,
    'owner': owner,
    'coverArt': coverArtId,
  };
}

@immutable
class Genre {
  const Genre(this.name, this.songCount);

  factory Genre.fromJson(Map<String, dynamic> json) => Genre(
    (json['value'] as String?) ?? '',
    (json['songCount'] as num?)?.toInt() ?? 0,
  );

  final String name;
  final int songCount;
}

class SearchResults {
  const SearchResults({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
  });

  final List<Song> songs;
  final List<Album> albums;
  final List<Artist> artists;

  bool get isEmpty => songs.isEmpty && albums.isEmpty && artists.isEmpty;
}
