import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/offline/file_fetcher.dart';
import 'package:yomi/core/offline/pooled_fetcher.dart';
import 'package:yomi/core/server_pool.dart';

const a = 'http://a:4533';
const b = 'http://b:4533';

class ScriptedFetcher implements FileFetcher {
  ScriptedFetcher(this.outcomes);

  final Map<String, Object> outcomes; // host -> FetchedFile | Exception
  final calls = <Uri>[];

  @override
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    void Function(double progress)? onProgress,
    CancelToken? cancel,
  }) async {
    calls.add(uri);
    final result = outcomes[uri.host];
    if (result is Exception) throw result;
    return result! as FetchedFile;
  }
}

void main() {
  final song = Uri.parse('http://a:4533/rest/download?id=1');
  final base = File('/tmp/never-written');
  final ok = FetchedFile(File('/tmp/x.mp3'), 10);
  late ServerPool pool;

  setUp(() => pool = ServerPool()..setServers(const [a, b]));

  test('fetches from the best-ranked server first', () async {
    pool.recordSuccess(b, const Duration(milliseconds: 5));
    pool.recordSuccess(a, const Duration(milliseconds: 500));
    final inner = ScriptedFetcher({'a': ok, 'b': ok});
    await PooledFetcher(pool: pool, inner: inner).fetch(song, base);
    expect(inner.calls.map((u) => u.host), ['b']);
  });

  test('falls back to the next server when one fails', () async {
    final inner = ScriptedFetcher({
      'a': const FetchFailed('Server answered 404.'),
      'b': ok,
    });
    final fetched = await PooledFetcher(
      pool: pool,
      inner: inner,
    ).fetch(song, base);
    expect(fetched, same(ok));
    expect(inner.calls.map((u) => u.host), ['a', 'b']);
    expect(pool.rank(), [b]);
  });

  test('throws the last error when every server fails', () async {
    final inner = ScriptedFetcher({
      'a': const FetchFailed('Cannot reach the server.'),
      'b': const FetchFailed('Server answered 404.'),
    });
    await expectLater(
      PooledFetcher(pool: pool, inner: inner).fetch(song, base),
      throwsA(
        isA<FetchFailed>().having((e) => e.message, 'message', contains('404')),
      ),
    );
    expect(inner.calls, hasLength(2));
  });

  test('does not try other servers when the user cancels', () async {
    final inner = ScriptedFetcher({'a': const FetchCancelled(), 'b': ok});
    await expectLater(
      PooledFetcher(pool: pool, inner: inner).fetch(song, base),
      throwsA(isA<FetchCancelled>()),
    );
    expect(inner.calls, hasLength(1));
    expect(pool.rank(), contains(a));
  });

  test('two fetches at once go to different servers', () async {
    pool.recordSuccess(a, const Duration(milliseconds: 50));
    pool.recordSuccess(b, const Duration(milliseconds: 60));
    final inner = _SlowFetcher(ok);
    final fetcher = PooledFetcher(pool: pool, inner: inner);
    final first = fetcher.fetch(song, base);
    final second = fetcher.fetch(song, base);
    await Future<void>.delayed(Duration.zero);
    inner.release();
    await Future.wait([first, second]);
    expect(inner.hosts.toSet(), {'a', 'b'});
  });

  test('connects through the tunnel address when the server has one', () async {
    final tunnelled = ServerPool()
      ..setServers(const [a])
      ..setRoute(a, 'http://127.0.0.1:9000');
    final inner2 = ScriptedFetcher({'127.0.0.1': ok});
    await PooledFetcher(pool: tunnelled, inner: inner2).fetch(song, base);
    expect(
      inner2.calls.single.toString(),
      'http://127.0.0.1:9000/rest/download?id=1',
    );
  });

  test('uses the original address when the pool is empty', () async {
    final empty = ServerPool();
    final inner = ScriptedFetcher({'a': ok});
    await PooledFetcher(pool: empty, inner: inner).fetch(song, base);
    expect(inner.calls.single, song);
  });
}

class _SlowFetcher implements FileFetcher {
  _SlowFetcher(this.result);

  final FetchedFile result;
  final hosts = <String>[];
  final _gate = _Gate();

  void release() => _gate.open();

  @override
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    void Function(double progress)? onProgress,
    CancelToken? cancel,
  }) async {
    hosts.add(uri.host);
    await _gate.future;
    return result;
  }
}

class _Gate {
  final _done = Future<void>.delayed(const Duration(milliseconds: 20));
  Future<void> get future => _done;
  void open() {}
}
