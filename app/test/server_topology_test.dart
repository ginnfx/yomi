import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/server_topology.dart';

void main() {
  test('moves the personal deployment to cloud with roaming Mac standby', () {
    final migrated = migrateCloudTopology(
      away: 'http://100.88.180.104:4533',
      home: 'http://192.168.1.18:4533',
      extras: [cloudMusicUrl, macMusicUrl, 'http://custom-backup:4533'],
    )!;
    expect(migrated.away, cloudMusicUrl);
    expect(migrated.home, isNull);
    expect(migrated.extras, [macMusicUrl, 'http://custom-backup:4533']);
  });

  test('keeps a custom main server unchanged', () {
    expect(
      migrateCloudTopology(
        away: 'https://music.example.com',
        home: null,
        extras: [macMusicUrl],
      ),
      isNull,
    );
  });

  test('also upgrades an old home address saved as the main server', () {
    expect(
      migrateCloudTopology(
        away: 'http://192.168.1.18:4533',
        home: null,
        extras: [],
      )!.away,
      cloudMusicUrl,
    );
  });

  test('preserves a deliberately configured custom home address', () {
    expect(
      migrateCloudTopology(
        away: macMusicUrl,
        home: 'http://custom-home:4533',
        extras: [],
      )!.home,
      'http://custom-home:4533',
    );
  });

  test('the built-in cloud server gets the Mac as its standby', () {
    expect(
      withDefaultBackup(away: cloudMusicUrl, home: null, extras: const []),
      [macMusicUrl],
    );
  });

  test('a standby that is already saved is not added twice', () {
    final extras = ['http://custom-backup:4533', macMusicUrl];
    expect(
      withDefaultBackup(away: cloudMusicUrl, home: null, extras: extras),
      extras,
    );
  });

  test('a custom main server keeps exactly the backups it has', () {
    expect(
      withDefaultBackup(
        away: 'https://music.example.com',
        home: null,
        extras: const ['http://custom-backup:4533'],
      ),
      ['http://custom-backup:4533'],
    );
  });
}
