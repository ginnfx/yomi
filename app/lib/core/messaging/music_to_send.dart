import 'package:diacritic/diacritic.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import '../search_index.dart';

/// How many of each kind a search offers.
const int kSongsPerSearch = 30;
const int kAlbumsPerSearch = 10;
const int kPlaylistsPerSearch = 10;

/// The fields a chat message needs to carry a piece of music.
typedef MusicMessage = ({
  String? songId,
  String? songTitle,
  String? albumId,
  String? playlistId,
});

/// Something picked to send in a chat: a song, an album or a playlist.
@immutable
sealed class PickedMusic {
  const PickedMusic();

  String get id;
  String get title;
  String get subtitle;
  String? get coverArtId;
  MusicMessage get message;
}

class PickedSong extends PickedMusic {
  const PickedSong(this.song);

  final Song song;

  @override
  String get id => 'song:${song.id}';
  @override
  String get title => song.title;
  @override
  String get subtitle => song.artist;
  @override
  String? get coverArtId => song.coverArtId;
  @override
  MusicMessage get message => (
    songId: song.id,
    songTitle: '${song.title} · ${song.artist}',
    albumId: null,
    playlistId: null,
  );
}

class PickedAlbum extends PickedMusic {
  const PickedAlbum({
    required this.albumId,
    required this.name,
    required this.artist,
    this.coverArtId,
  });

  final String albumId;
  final String name;
  final String artist;
  @override
  final String? coverArtId;

  @override
  String get id => 'album:$albumId';
  @override
  String get title => name;
  @override
  String get subtitle => 'Album · $artist';
  @override
  MusicMessage get message =>
      (songId: null, songTitle: null, albumId: albumId, playlistId: null);
}

class PickedPlaylist extends PickedMusic {
  const PickedPlaylist(this.playlist);

  final Playlist playlist;

  @override
  String get id => 'playlist:${playlist.id}';
  @override
  String get title => playlist.name;
  @override
  String get subtitle => 'Playlist · ${playlist.songCount} songs';
  @override
  String? get coverArtId => playlist.coverArtId;
  @override
  MusicMessage get message =>
      (songId: null, songTitle: null, albumId: null, playlistId: playlist.id);
}

/// Every album in the library once, most recently added first.
List<PickedAlbum> albumsToSend(List<Song> songs) {
  final newest = <String, Song>{};
  for (final song in songs) {
    final albumId = song.albumId;
    if (albumId == null) continue;
    final known = newest[albumId];
    if (known == null || _addedAt(song).isAfter(_addedAt(known))) {
      newest[albumId] = song;
    }
  }
  final ordered = newest.entries.toList()
    ..sort((a, b) => _addedAt(b.value).compareTo(_addedAt(a.value)));
  return List.unmodifiable([
    for (final entry in ordered)
      PickedAlbum(
        albumId: entry.key,
        name: entry.value.album,
        artist: entry.value.artist,
        coverArtId: entry.value.coverArtId,
      ),
  ]);
}

DateTime _addedAt(Song song) =>
    song.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

/// Liked songs, in library order.
List<PickedSong> likedToSend(List<Song> songs) => List.unmodifiable([
  for (final song in songs)
    if (song.isStarred) PickedSong(song),
]);

/// Songs, then albums, then playlists matching [query].
List<PickedMusic> searchToSend(
  String query, {
  required SearchIndex index,
  required List<Playlist> playlists,
}) {
  final text = query.trim();
  if (text.isEmpty) return const [];
  final results = index.search(text);
  final wanted = _plain(text);
  return List.unmodifiable([
    for (final song in results.songs.take(kSongsPerSearch)) PickedSong(song),
    for (final album in results.albums.take(kAlbumsPerSearch))
      PickedAlbum(
        albumId: album.id,
        name: album.name,
        artist: album.artist,
        coverArtId: album.coverArtId,
      ),
    ...playlists
        .where((playlist) => _plain(playlist.name).contains(wanted))
        .take(kPlaylistsPerSearch)
        .map(PickedPlaylist.new),
  ]);
}

String _plain(String text) => removeDiacritics(text).toLowerCase();
