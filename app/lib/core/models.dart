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
