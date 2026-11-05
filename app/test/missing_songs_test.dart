import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/spotify/imported_playlist.dart';
import 'package:yomi/core/spotify/missing_songs.dart';

void main() {
  test('lists songs missing from imports once, with the playlists they came from', () {
    final missing = missingFromImports(const [
      ImportedPlaylist(
        id: '1',
        name: 'Gym',
        entries: [
          ImportEntry(title: 'Have', artist: 'X', songId: 's1'),
          ImportEntry(title: 'Lose Yourself', artist: 'Eminem'),
          ImportEntry(title: 'Stronger', artist: 'Kanye West'),
        ],
      ),
      ImportedPlaylist(
        id: '2',
        name: 'Road',
        entries: [ImportEntry(title: 'lose yourself ', artist: 'EMINEM')],
      ),
    ]);
    expect(missing.map((m) => m.title), ['Lose Yourself', 'Stronger']);
    expect(missing.first.playlists, ['Gym', 'Road']);
    expect(missing.last.playlists, ['Gym']);
  });

  test('nothing missing means nothing to suggest', () {
    expect(missingFromImports(const []), isEmpty);
  });
}
