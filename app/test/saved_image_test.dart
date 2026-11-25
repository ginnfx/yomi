import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/saved_image.dart';

void main() {
  test('the same picture keeps its key across logins and addresses', () {
    final home = savedImageKey(
      'http://192.168.1.5:4534/v1/playlists/p1/cover?u=me&t=aaa&s=111&c=yomi&f=json&v=3',
    );
    final away = savedImageKey(
      'http://100.70.1.2:4534/v1/playlists/p1/cover?u=me&t=bbb&s=222&c=yomi&f=json&v=3',
    );
    expect(home, away);
  });

  test('a new picture version gets a new key', () {
    expect(
      savedImageKey('http://h/v1/profiles/a/avatar?t=x&v=1'),
      isNot(savedImageKey('http://h/v1/profiles/a/avatar?t=x&v=2')),
    );
  });

  test('outside pictures keep their host, so two sites never share a key', () {
    expect(
      savedImageKey('https://a.example/art.jpg'),
      isNot(savedImageKey('https://b.example/art.jpg')),
    );
  });
}
