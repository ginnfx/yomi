import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/subsonic_client.dart';

const _body = '''
{"subsonic-response":{"status":"ok","playlists":{"playlist":[
  {"id":"1","name":"Mine","owner":"Me","songCount":1,"duration":10},
  {"id":"2","name":"Theirs","owner":"admin2","songCount":2,"duration":20,"public":true},
  {"id":"3","name":"No owner","songCount":3,"duration":30}
]}}}''';

SubsonicClient _client() => SubsonicClient(
  baseUrl: 'http://s',
  username: 'me',
  password: 'p',
  httpClient: MockClient((_) async => http.Response(_body, 200)),
);

void main() {
  test('lists only the playlists this account owns', () async {
    final names = (await _client().playlists()).map((p) => p.name).toList();

    expect(names, ['Mine', 'No owner']);
  });

  test('the saved copy hides other accounts\' playlists too', () async {
    final client = _client();
    await client.playlists();

    final names = client.cachedPlaylists?.map((p) => p.name).toList();

    expect(names, isNot(contains('Theirs')));
  });
}
