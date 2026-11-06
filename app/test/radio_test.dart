import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/ai/ai_api.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/radio.dart';

Song song(String id, String artist, {String? genre}) => Song(
  id: id,
  title: 'Song $id',
  artist: artist,
  album: 'Album',
  durationSeconds: 200,
  genre: genre,
);

void main() {
  final seed = song('seed', 'Mira', genre: 'Pop');
  final library = [
    seed,
    song('a1', 'Mira'),
    song('a2', 'Mira'),
    song('a3', 'Mira'),
    song('a4', 'Mira'),
    song('n1', 'Nova'),
    song('n2', 'Nova'),
    song('x1', 'Stranger', genre: 'Metal'),
    song('c1', 'Calmer'),
  ];
  final tags = {
    'Song seed': const SongTag(moods: ['calm'], energy: 'low'),
    'Song c1': const SongTag(moods: ['calm'], energy: 'low'),
    'Song x1': const SongTag(moods: ['angry'], energy: 'high'),
  };
  SongTag? tagFor(Song s) => tags[s.title];

  List<Song> radio({Set<String> exclude = const {}}) => radioFrom(
    seed,
    library: library,
    tagFor: tagFor,
    similarArtists: const {
      'Mira': ['Nova'],
    },
    exclude: exclude,
  );

  test('similar artists and matching moods come before unrelated songs', () {
    // Act
    final songs = radio();

    // Assert
    final ids = songs.map((s) => s.id).toList();
    expect(ids, isNot(contains('x1')));
    expect(ids.indexOf('n1'), lessThan(ids.length));
    expect(ids, contains('c1'));
  });

  test('never repeats the seed or what is already queued', () {
    // Act
    final songs = radio(exclude: {'n1'});

    // Assert
    expect(songs.map((s) => s.id), isNot(contains('seed')));
    expect(songs.map((s) => s.id), isNot(contains('n1')));
  });

  test('keeps any one artist from taking over', () {
    // Act
    final songs = radio();

    // Assert
    expect(songs.where((s) => s.artist == 'Mira'), hasLength(kRadioPerArtist));
  });

  test(
    'gives the same order for the same song, so the queue does not jump',
    () {
      // Act / Assert
      expect(radio().map((s) => s.id), radio().map((s) => s.id));
    },
  );

  test('songs from YouTube are never suggested', () {
    // Arrange
    final withYoutube = [...library, song('yt:abc', 'Nova')];

    // Act
    final songs = radioFrom(
      seed,
      library: withYoutube,
      tagFor: tagFor,
      similarArtists: const {
        'Mira': ['Nova'],
      },
    );

    // Assert
    expect(songs.map((s) => s.id), isNot(contains('yt:abc')));
  });
}
