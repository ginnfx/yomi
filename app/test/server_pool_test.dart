import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/server_pool.dart';

const a = 'http://a:4533';
const b = 'http://b:4533';
const c = 'http://c:4533';

void main() {
  late DateTime clock;
  late ServerPool pool;

  setUp(() {
    clock = DateTime(2026, 11, 8, 12);
    pool = ServerPool(cooldown: const Duration(seconds: 30), now: () => clock)
      ..setServers(const [a, b, c]);
  });

  test('ranks untried servers in the given order', () {
    expect(pool.rank(), [a, b, c]);
  });

  test('prefers the server that answered fastest', () {
    pool.recordSuccess(a, const Duration(milliseconds: 400));
    pool.recordSuccess(b, const Duration(milliseconds: 40));
    pool.recordSuccess(c, const Duration(milliseconds: 150));
    expect(pool.rank(), [b, c, a]);
  });

  test('sends new work to the idle server while another is busy', () {
    pool.recordSuccess(a, const Duration(milliseconds: 50));
    pool.recordSuccess(b, const Duration(milliseconds: 60));
    final release = pool.lease(a);
    expect(pool.rank().first, b);
    release();
    expect(pool.rank().first, a);
  });

  test('skips a failed server until its cooldown ends', () {
    pool.recordFailure(a);
    expect(pool.rank(), [b, c]);
    clock = clock.add(const Duration(seconds: 31));
    expect(pool.rank(), contains(a));
  });

  test('a success clears the failure', () {
    pool.recordFailure(a);
    pool.recordSuccess(a, const Duration(milliseconds: 20));
    expect(pool.rank(), contains(a));
  });

  test('keeps every server as a last resort when all have failed', () {
    pool
      ..recordFailure(a)
      ..recordFailure(b)
      ..recordFailure(c);
    expect(pool.rank(), unorderedEquals([a, b, c]));
  });

  test('release is safe to call twice', () {
    final release = pool.lease(a);
    release();
    release();
    pool.recordSuccess(a, const Duration(milliseconds: 10));
    pool.recordSuccess(b, const Duration(milliseconds: 10));
    expect(pool.rank().first, a);
  });

  test('setServers drops removed servers and keeps stats of the rest', () {
    pool.recordSuccess(b, const Duration(milliseconds: 10));
    pool.setServers(const [b, c]);
    expect(pool.rank(), [b, c]);
    expect(pool.servers, [b, c]);
  });

  test('resolves a server through its tunnel route until cleared', () {
    expect(pool.resolve(a), a);
    pool.setRoute(a, 'http://127.0.0.1:9000/');
    expect(pool.resolve(a), 'http://127.0.0.1:9000');
    pool.setRoute(a, null);
    expect(pool.resolve(a), a);
  });

  test('rebases a media address onto another server', () {
    final original = Uri.parse(
      'http://a:4533/rest/download?id=1&u=x&t=y&s=z&v=1.16.1&c=yomi',
    );
    expect(
      rebaseOnServer(original, 'http://b:4533').toString(),
      'http://b:4533/rest/download?id=1&u=x&t=y&s=z&v=1.16.1&c=yomi',
    );
  });

  test('rebases when the server lives under a path prefix', () {
    final original = Uri.parse('http://a/music/rest/download?id=1');
    expect(
      rebaseOnServer(original, 'https://b.example/navi').toString(),
      'https://b.example/navi/rest/download?id=1',
    );
  });

  test('leaves addresses without /rest/ unchanged', () {
    final original = Uri.parse('http://a:4533/other?id=1');
    expect(rebaseOnServer(original, 'http://b:4533'), original);
  });
}
