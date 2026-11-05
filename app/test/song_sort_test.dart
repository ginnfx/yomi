import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/song_sort.dart';
import 'package:yomi/core/taste.dart';

Song song(
  String id, {
  String title = 'T',
  String artist = 'A',
  int plays = 0,
  DateTime? added,
  bool starred = false,
}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: 'Album',
  durationSeconds: 100,
  playCount: plays,
  addedAt: added,
  isStarred: starred,
);

void main() {
  final songs = [
    song('a', title: 'beta', artist: 'Zed', plays: 5, added: DateTime(2024)),
    song('b', title: 'Alpha', artist: 'amy', plays: 0, added: DateTime(2026), starred: true),
    song('c', title: 'gamma', artist: 'Bob', plays: 9, added: null),
  ];
  List<String> ids(List<Song> list) => [for (final s in list) s.id];

  test('sorts by date added, newest first, undated last', () {
    expect(ids(sortSongs(songs, SongSort.recentlyAdded)), ['b', 'a', 'c']);
  });

  test('sorts by plays, title and artist', () {
    expect(ids(sortSongs(songs, SongSort.mostPlayed)), ['c', 'a', 'b']);
    expect(ids(sortSongs(songs, SongSort.title)), ['b', 'a', 'c']);
    expect(ids(sortSongs(songs, SongSort.artist)), ['b', 'c', 'a']);
  });

  test('"for you" puts this person\'s favourites first', () {
    const taste = TasteProfile(artists: {'Zed': 5});
    expect(sortSongs(songs, SongSort.forYou, taste: taste).first.id, 'a');
  });

  test('filters keep only liked or not yet played songs', () {
    expect(ids(filterSongs(songs, likedOnly: true)), ['b']);
    expect(ids(filterSongs(songs, unplayedOnly: true)), ['b']);
    expect(filterSongs(songs), same(songs));
  });

  test('every sort has a label', () {
    for (final sort in SongSort.values) {
      expect(sort.label, isNotEmpty);
    }
  });
}
