import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/search_index.dart';

Song _song(
  String id,
  String title,
  String artist, {
  String album = 'Album',
  int plays = 0,
}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: album,
  albumId: 'al-$album',
  durationSeconds: 200,
  playCount: plays,
);

final _library = [
  _song('around', 'Around the World', 'Daft Punk', album: 'Homework'),
  _song('harder', 'Harder, Better, Faster, Stronger', 'Daft Punk', album: 'Discovery'),
  _song('digital', 'Digital Love', 'Daft Punk', album: 'Discovery'),
  _song('beyonce', 'Halo', 'Beyoncé', album: 'I Am... Sasha Fierce'),
  _song('sigur', 'Hoppípolla', 'Sigur Rós', album: 'Takk...'),
  _song('utada', '誰にも言わない', '宇多田ヒカル', album: 'Fantôme'),
  _song('ado', '新時代', 'Ado', album: 'ウタの歌'),
  _song('bts', '봄날', 'BTS', album: 'You Never Walk Alone'),
  _song('world', 'World', 'Five for Fighting', album: 'The Battle for Everything'),
  _song('love', 'Love', 'Lana Del Rey', album: 'Lust for Life'),
  _song('lover', 'Lover', 'Taylor Swift', album: 'Lover'),
  _song('acdc', 'Thunderstruck', 'AC/DC', album: 'The Razors Edge'),
];

List<String> _ids(SearchIndex index, String query) => [
  for (final song in index.search(query).songs) song.id,
];

void main() {
  final index = SearchIndex(_library);

  group('finds what you meant', () {
    final cases = <(String, String, String)>[
      ('exact title', 'Digital Love', 'digital'),
      ('case', 'DIGITAL love', 'digital'),
      ('word prefix', 'digi', 'digital'),
      ('prefix of a later word', 'harder bet', 'harder'),
      ('typo in title', 'digitl love', 'digital'),
      ('swapped letters', 'digtial', 'digital'),
      ('typo in artist', 'daft punl around', 'around'),
      ('words across fields', 'daft around', 'around'),
      ('album', 'homework', 'around'),
      ('without accents', 'beyonce', 'beyonce'),
      ('with accents typed', 'Beyoncé', 'beyonce'),
      ('accents across the word', 'hoppipolla', 'sigur'),
      ('artist accent', 'sigur ros', 'sigur'),
      ('japanese title', '誰にも', 'utada'),
      ('japanese part of a title', '時代', 'ado'),
      ('japanese artist', '宇多田', 'utada'),
      ('korean', '봄날', 'bts'),
      ('punctuation in the name', 'ac dc', 'acdc'),
      ('punctuation typed', 'ac/dc', 'acdc'),
      ('extra spaces', '  digital    love ', 'digital'),
    ];
    for (final (name, query, expected) in cases) {
      test('$name: "$query"', () {
        expect(_ids(index, query).first, expected);
      });
    }
  });

  group('ranking', () {
    test('an exact title beats a partial match', () {
      expect(_ids(index, 'love').first, 'love');
      expect(_ids(index, 'love'), contains('digital'));
    });

    test('a title match beats an artist or album match', () {
      final library = [
        _song('album', 'Other', 'Other', album: 'Sunset'),
        _song('artist', 'Other', 'Sunset', album: 'Other'),
        _song('title', 'Sunset', 'Other', album: 'Other'),
      ];
      expect(_ids(SearchIndex(library), 'sunset'), ['title', 'artist', 'album']);
    });

    test('a real word beats a typo match', () {
      final library = [
        _song('typo', 'Lover', 'A'),
        _song('real', 'Lovers', 'A'),
      ];
      expect(_ids(SearchIndex(library), 'lovers').first, 'real');
    });

    test('your plays break ties', () {
      final library = [
        _song('rare', 'Dream', 'A'),
        _song('often', 'Dream', 'B', plays: 50),
      ];
      expect(_ids(SearchIndex(library), 'dream').first, 'often');
    });

    test('every word typed has to match', () {
      expect(_ids(index, 'daft thunderstruck'), isEmpty);
    });

    test('short words need an exact start, so results stay relevant', () {
      expect(_ids(index, 'zz'), isEmpty);
      expect(_ids(index, 'lo'), containsAll(['love', 'lover', 'digital']));
    });

    test('nothing typed means no results, not everything', () {
      expect(_ids(index, ''), isEmpty);
      expect(_ids(index, '   '), isEmpty);
    });
  });

  group('groups', () {
    test('finds artists by name, with a song count', () {
      final results = index.search('daft');
      expect(results.artists.first.name, 'Daft Punk');
      expect(results.artists.first.songCount, 3);
    });

    test('splits credits into single artists, merged and capped', () {
      final library = [
        _song('1', 'a', 'アトラスサウンドチーム & ATLUS GAME MUSIC'),
        _song('2', 'b', 'Lyn, ATLUS GAME MUSIC'),
        _song('3', 'c', 'ＡＴＬＵＳ Game Music'),
        for (var i = 0; i < 8; i++) _song('x$i', 't$i', 'Atlus Band $i, Foo'),
      ];
      final artists = SearchIndex(library).search('atlus').artists;
      final names = artists.map((a) => a.name).toList();
      expect(names.first, 'ATLUS GAME MUSIC');
      expect(artists.first.songCount, 3);
      expect(artists.length, lessThanOrEqualTo(5));
      expect(names, isNot(contains('Lyn')));
      expect(names, isNot(contains('Foo')));
    });

    test('finds albums once each, with their artist', () {
      final results = index.search('discovery');
      expect(results.albums.single.name, 'Discovery');
      expect(results.albums.single.artist, 'Daft Punk');
      expect(results.albums.single.id, 'al-Discovery');
    });

    test('the top result is the artist when the search is their name', () {
      final top = index.search('daft punk').topResult;
      expect(top, isA<ArtistMatch>());
    });

    test('the top result is the song when the search is its title', () {
      final top = index.search('thunderstruck').topResult;
      expect(top, isA<SongMatch>());
      expect((top! as SongMatch).song.id, 'acdc');
    });
  });

  test('stays fast on a library bigger than yours', () {
    final big = [
      for (var i = 0; i < 5000; i++)
        _song(
          '$i',
          'Title number ${i % 37} word$i',
          'Artist ${i % 200}',
          album: 'Album ${i % 500}',
        ),
    ];
    final built = Stopwatch()..start();
    final bigIndex = SearchIndex(big);
    built.stop();
    bigIndex.search('warmup');
    final times = <int>[];
    for (final query in ['title numbr', 'artist 12 word5', 'albm 99', 'word4321']) {
      final timer = Stopwatch()..start();
      bigIndex.search(query);
      times.add(timer.elapsedMicroseconds);
    }
    times.sort();
    // ignore: avoid_print
    print('Index built in ${built.elapsedMilliseconds} ms; searches $times us');
    // Generous, because this machine is often busy: a phone frame is 16 ms.
    expect(times[times.length ~/ 2], lessThan(50000));
  });
}
