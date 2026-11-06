import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomi/core/cover_downloader.dart';

final Uint8List _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]);

void main() {
  test('recognises pictures and rejects error messages', () {
    expect(looksLikeImage(_jpeg), isTrue);
    expect(
      looksLikeImage(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
      isTrue,
    );
    expect(
      looksLikeImage(Uint8List.fromList('{"error":1}'.codeUnits)),
      isFalse,
    );
    expect(looksLikeImage(Uint8List(0)), isFalse);
  });

  CoverDownloader downloader(
    Future<http.Response> Function(http.Request) answer, {
    int maxAtOnce = 6,
    Duration timeout = const Duration(seconds: 5),
  }) => CoverDownloader(
    newClient: () => MockClient(answer),
    maxAtOnce: maxAtOnce,
    requestTimeout: timeout,
  );

  test('returns the picture', () async {
    final loader = downloader((_) async => http.Response.bytes(_jpeg, 200));
    expect(await loader.fetch('http://s/a'), _jpeg);
  });

  test(
    'a missing cover and an error message mean there is no picture',
    () async {
      final missing = downloader((_) async => http.Response('', 404));
      await expectLater(
        missing.fetch('http://s/a'),
        throwsA(isA<CoverNotAvailable>()),
      );
      final text = downloader(
        (_) async => http.Response('{"status":"failed"}', 200),
      );
      await expectLater(
        text.fetch('http://s/a'),
        throwsA(isA<CoverNotAvailable>()),
      );
    },
  );

  test('a server having trouble is worth trying again', () async {
    final loader = downloader((_) async => http.Response('', 503));
    await expectLater(
      loader.fetch('http://s/a'),
      throwsA(isNot(isA<CoverNotAvailable>())),
    );
  });

  test('only a few run at once, and the rest get a turn', () async {
    var running = 0;
    var most = 0;
    final release = Completer<void>();
    final loader = downloader((_) async {
      running++;
      if (running > most) most = running;
      await release.future;
      running--;
      return http.Response.bytes(_jpeg, 200);
    }, maxAtOnce: 2);
    final all = [for (var i = 0; i < 6; i++) loader.fetch('http://s/$i')];
    await Future<void>.delayed(Duration.zero);
    expect(most, 2);
    release.complete();
    await Future.wait(all);
    expect(most, 2);
  });

  test(
    'the newest request goes first, so what is on screen isn\'t kept waiting',
    () async {
      final first = Completer<http.Response>();
      final order = <String>[];
      final loader = downloader((request) {
        order.add(request.url.path);
        return request.url.path == '/scrolled-past-1'
            ? first.future
            : Future.value(http.Response.bytes(_jpeg, 200));
      }, maxAtOnce: 1);

      final all = [
        for (final name in const [
          'scrolled-past-1',
          'scrolled-past-2',
          'scrolled-past-3',
          'on-screen',
        ])
          loader.fetch('http://s/$name'),
      ];
      await Future<void>.delayed(Duration.zero);
      first.complete(http.Response.bytes(_jpeg, 200));
      await Future.wait(all);

      expect(order, [
        '/scrolled-past-1',
        '/on-screen',
        '/scrolled-past-3',
        '/scrolled-past-2',
      ]);
    },
  );

  test('says when it is busy', () async {
    final release = Completer<http.Response>();
    final loader = downloader((_) => release.future);
    expect(loader.isBusy, isFalse);
    final request = loader.fetch('http://s/a');
    expect(loader.isBusy, isTrue);
    release.complete(http.Response.bytes(_jpeg, 200));
    await request;
    expect(loader.isBusy, isFalse);
  });

  test('a request that stalls gives up its turn', () async {
    final never = Completer<http.Response>();
    var calls = 0;
    final loader = downloader(
      (_) {
        calls++;
        return calls == 1
            ? never.future
            : Future.value(http.Response.bytes(_jpeg, 200));
      },
      maxAtOnce: 1,
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      loader.fetch('http://s/stuck'),
      throwsA(isA<TimeoutException>()),
    );
    expect(await loader.fetch('http://s/next'), _jpeg);
  });

  test(
    'cancelling drops those waiting, and new requests are not held back',
    () async {
      final stuck = Completer<http.Response>();
      final urls = <String>[];
      final loader = downloader((request) {
        urls.add(request.url.path);
        return request.url.path == '/stuck'
            ? stuck.future
            : Future.value(http.Response.bytes(_jpeg, 200));
      }, maxAtOnce: 1);

      final first = loader.fetch('http://old/stuck');
      final queued = loader.fetch('http://old/queued');
      await Future<void>.delayed(Duration.zero);

      loader.cancelAll();
      final fresh = loader.fetch('http://new/fresh');
      stuck.completeError(Exception('closed'));

      await expectLater(first, throwsA(anything));
      await expectLater(queued, throwsA(isA<StateError>()));
      expect(await fresh, _jpeg);
      expect(urls, isNot(contains('/queued')));
    },
  );

  sharedPoolTests();
}

class _Calls {
  final List<Uri> urls = [];
}

void sharedPoolTests() {
  const navidrome =
      'http://music:4533/rest/getCoverArt?u=a&t=T&s=S&id=al-1_ab&size=240';

  group('poolCoverUri', () {
    test('points a Navidrome cover address at the upload service', () {
      final pooled = poolCoverUri(Uri.parse(navidrome), 4534)!;

      expect(pooled.port, 4534);
      expect(pooled.path, '/v1/pool/cover/al-1_ab');
      expect(pooled.queryParameters['size'], '240');
      expect(pooled.queryParameters['u'], 'a');
    });

    test('leaves other addresses alone', () {
      expect(poolCoverUri(Uri.parse('http://x/art.jpg'), 4534), isNull);
      expect(
        poolCoverUri(Uri.parse('http://m:4533/rest/getCoverArt?u=a'), 4534),
        isNull,
      );
    });

    test('keeps odd characters in an ID from changing the path', () {
      final pooled = poolCoverUri(
        Uri.parse('http://m:4533/rest/getCoverArt?id=a%2F..%2Fb'),
        4534,
      )!;

      expect(pooled.path, '/v1/pool/cover/a%2F..%2Fb');
    });
  });

  CoverDownloader pooled(Future<http.Response> Function(http.Request) answer) =>
      CoverDownloader(
        newClient: () => MockClient(answer),
        uploadPortFor: (_) => 4534,
      );

  test('asks the shared pool first and uses its picture', () async {
    final calls = _Calls();
    final loader = pooled((request) async {
      calls.urls.add(request.url);
      return http.Response.bytes(_jpeg, 200);
    });

    expect(await loader.fetch(navidrome), _jpeg);
    expect(calls.urls.map((u) => u.port), [4534]);
  });

  test('falls back to Navidrome when the pool does not answer', () async {
    final calls = _Calls();
    final loader = pooled((request) async {
      calls.urls.add(request.url);
      return request.url.port == 4534
          ? http.Response('404 page not found', 404)
          : http.Response.bytes(_jpeg, 200);
    });

    expect(await loader.fetch(navidrome), _jpeg);
    expect(calls.urls.map((u) => u.port), [4534, 4533]);
  });

  test('stops asking an upload service that has no pool', () async {
    final calls = _Calls();
    final loader = pooled((request) async {
      calls.urls.add(request.url);
      return request.url.port == 4534
          ? http.Response('404 page not found', 404)
          : http.Response.bytes(_jpeg, 200);
    });

    await loader.fetch(navidrome);
    await loader.fetch(navidrome);

    expect(calls.urls.map((u) => u.port), [4534, 4533, 4533]);
  });

  test('keeps using the pool after it says one cover is missing', () async {
    final calls = _Calls();
    final loader = pooled((request) async {
      calls.urls.add(request.url);
      if (request.url.port != 4534) return http.Response.bytes(_jpeg, 200);
      return request.url.path.endsWith('al-1_ab')
          ? http.Response('{"message":"no such cover"}', 404)
          : http.Response.bytes(_jpeg, 200);
    });

    await loader.fetch(navidrome);
    await loader.fetch(navidrome.replaceAll('al-1_ab', 'al-2'));

    expect(calls.urls.map((u) => u.port), [4534, 4533, 4534]);
  });

  test('falls back when the pool cannot be reached', () async {
    final loader = pooled((request) async {
      if (request.url.port == 4534) throw const SocketException('refused');
      return http.Response.bytes(_jpeg, 200);
    });

    expect(await loader.fetch(navidrome), _jpeg);
  });

  test('never sends other addresses to the pool', () async {
    final calls = _Calls();
    final loader = pooled((request) async {
      calls.urls.add(request.url);
      return http.Response.bytes(_jpeg, 200);
    });

    await loader.fetch('http://x/art.jpg');

    expect(calls.urls.map((u) => u.host), ['x']);
  });
}
