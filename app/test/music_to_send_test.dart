import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/messaging/music_to_send.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/search_index.dart';

Song song(
  String id, {
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  String? albumId,
  bool isStarred = false,
  DateTime? addedAt,
}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: album,
  albumId: albumId,
  durationSeconds: 200,
  isStarred: isStarred,
  addedAt: addedAt,
);

Playlist playlist(String id, String name) =>
    Playlist(id: id, name: name, songCount: 3, durationSeconds: 600);

void main() {
  group('albumsToSend', () {
    test('lists each album once, newest additions first', () {
      // Arrange
      final songs = [
        song('1', album: 'Old', albumId: 'a1', addedAt: DateTime(2020)),
        song('2', album: 'New', albumId: 'a2', addedAt: DateTime(2026)),
        song('3', album: 'Old', albumId: 'a1', addedAt: DateTime(2021)),
      ];

      // Act
      final albums = albumsToSend(songs);

      // Assert
      expect(albums.map((a) => a.name), ['New', 'Old']);
    });

    test('skips songs that belong to no album', () {
      // Act
      final albums = albumsToSend([song('1')]);

      // Assert
      expect(albums, isEmpty);
    });
  });

  test('likedToSend keeps only liked songs', () {
    // Arrange
    final songs = [song('1', isStarred: true), song('2')];

    // Act
    final liked = likedToSend(songs);

    // Assert
    expect(liked.map((s) => s.song.id), ['1']);
  });

  group('searchToSend', () {
    final songs = [
      song('1', title: 'Blue Hour', album: 'Night Drive', albumId: 'a1'),
      song('2', title: 'Red Sky', album: 'Night Drive', albumId: 'a1'),
    ];
    final index = SearchIndex(songs);

    test('finds songs, albums and playlists at once', () {
      // Act
      final found = searchToSend(
        'night',
        index: index,
        playlists: [playlist('p1', 'Night walks'), playlist('p2', 'Gym')],
      );

      // Assert
      expect(found.whereType<PickedAlbum>().map((a) => a.name), [
        'Night Drive',
      ]);
      expect(found.whereType<PickedPlaylist>().map((p) => p.playlist.id), [
        'p1',
      ]);
    });

    test('matches playlist names without caring about case or accents', () {
      // Act
      final found = searchToSend(
        'cafe',
        index: index,
        playlists: [playlist('p1', 'Café Mornings')],
      );

      // Assert
      expect(found.whereType<PickedPlaylist>(), hasLength(1));
    });

    test('returns nothing for an empty query', () {
      // Act
      final found = searchToSend('  ', index: index, playlists: const []);

      // Assert
      expect(found, isEmpty);
    });
  });

  group('what gets sent', () {
    test('a song sends its id and a readable title', () {
      // Act
      final message = PickedSong(song('7', title: 'Hi', artist: 'Me')).message;

      // Assert
      expect(message.songId, '7');
      expect(message.songTitle, 'Hi · Me');
      expect(message.albumId, isNull);
    });

    test('an album sends only its id', () {
      // Act
      final message = const PickedAlbum(
        albumId: 'a1',
        name: 'Night Drive',
        artist: 'X',
      ).message;

      // Assert
      expect(message.albumId, 'a1');
      expect(message.songId, isNull);
    });

    test('a playlist sends only its id', () {
      // Act
      final message = PickedPlaylist(playlist('p1', 'Gym')).message;

      // Assert
      expect(message.playlistId, 'p1');
      expect(message.songId, isNull);
    });
  });
}
