import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/state/settings.dart';

Playlist _p(String id) =>
    Playlist(id: id, name: id, songCount: 0, durationSeconds: 0);

void main() {
  test(
    'saved order wins, new playlists go on top, deleted ones are dropped',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await SettingsController.load();
      await settings.setPlaylistOrder(['c', 'a', 'gone', 'b']);
      final ordered = settings.orderPlaylists([
        _p('a'),
        _p('b'),
        _p('c'),
        _p('new'),
      ]);
      expect(ordered.map((p) => p.id), ['new', 'c', 'a', 'b']);
    },
  );

  test('without a saved order the server order is kept', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsController.load();
    expect(settings.orderPlaylists([_p('x'), _p('y')]).map((p) => p.id), [
      'x',
      'y',
    ]);
  });
}
