import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/messaging/messaging_api.dart';
import 'package:yomi/core/messaging/share_info.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/subsonic_client.dart';

ChatMessage _message({String? songId, String? albumId, String? title}) =>
    ChatMessage(
      id: 1,
      from: 'a',
      to: 'b',
      text: '',
      sentAt: DateTime(2026),
      songId: songId,
      albumId: albumId,
      songTitle: title,
    );

void main() {
  late SubsonicClient client;

  setUp(() {
    client = SubsonicClient(
      baseUrl: 'http://server',
      username: 'u',
      password: 'p',
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
  });

  test('a shared song found in the library needs no request', () async {
    const song = Song(
      id: 's1',
      title: 'Title',
      artist: 'Artist',
      album: 'Album',
      durationSeconds: 100,
      coverArtId: 'cover-1',
    );

    final info = await loadShareInfo(
      _message(songId: 's1'),
      client,
      library: const [song],
    );

    expect(info!.kind, ShareKind.song);
    expect(info.title, 'Title');
    expect(info.subtitle, 'Artist');
    expect(info.coverArtId, 'cover-1');
  });

  test('a share that cannot be found returns null instead of throwing', () async {
    final info = await loadShareInfo(_message(albumId: 'gone'), client);

    expect(info, isNull);
  });

  test('a message without a share has no share info', () async {
    expect(await loadShareInfo(_message(), client), isNull);
    expect(shareKindOf(_message()), isNull);
  });
}
