import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/cover_crop.dart';
import 'package:yomi/core/cover_downloader.dart';
import 'package:yomi/core/cover_sizes.dart';
import 'package:yomi/state/session.dart';
import 'package:yomi/ui/widgets/cover_art.dart';

import 'support/screen_harness.dart';

class _FakeSource implements CoverSource {
  final Map<String, Uint8List> onDevice = {};
  final Map<String, Uint8List> onServer = {};
  final Map<String, Completer<Uint8List>> held = {};
  final List<String> downloads = [];
  final List<String> forgotten = [];
  final Set<String> notOnServer = {};
  final Set<String> temporarilyMissing = {};
  int cancels = 0;

  @override
  bool get isBusy => false;

  @override
  Future<Set<String>> savedKeys() async => onDevice.keys.toSet();

  @override
  Future<Uint8List?> saved(String cacheKey) async => onDevice[cacheKey];

  @override
  Future<Uint8List> download(String url, String cacheKey) async {
    downloads.add(cacheKey);
    if (temporarilyMissing.contains(cacheKey)) {
      throw const CoverNotAvailable('replica placeholder', isTransient: true);
    }
    if (notOnServer.contains(cacheKey)) {
      throw const CoverNotAvailable('test');
    }
    final wait = held[cacheKey];
    if (wait != null) return wait.future;
    final bytes = onServer[cacheKey];
    if (bytes == null) throw Exception('not reachable');
    onDevice[cacheKey] = bytes;
    return bytes;
  }

  @override
  Future<void> forget(String cacheKey) async {
    forgotten.add(cacheKey);
    onDevice.remove(cacheKey);
  }

  @override
  void cancelDownloads() => cancels++;
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var i = 0; i < 8; i++) {
    canvas.drawRect(
      ui.Rect.fromLTWH(i.toDouble(), 0, 1, 8),
      ui.Paint()..color = ui.Color.fromARGB(255, i * 30, 255 - i * 30, i * 10),
    );
  }
  final image = await recorder.endRecording().toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  late _FakeSource source;
  late CoverImageService service;
  late DateTime now;
  late CoverImageService original;

  setUp(() {
    source = _FakeSource();
    now = DateTime(2026, 11, 5, 12);
    service = CoverImageService(source: source, now: () => now);
    original = CoverImageService.instance;
    CoverImageService.instance = service;
  });

  tearDown(() => CoverImageService.instance = original);

  testWidgets('a cached Navidrome placeholder is replaced with real artwork', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final placeholder = await File('test/fixtures/navidrome-placeholder.webp')
          .readAsBytes();
      source.onDevice['stale'] = placeholder;
      final real = await _png();
      source.onServer['stale'] = real;
      expect(await service.load('http://server/cover', 'stale'), isNotNull);
      expect(source.forgotten, contains('stale'));
      expect(source.downloads, ['stale']);
      expect(source.onDevice['stale'], real);
    });
  });

  testWidgets('a cover on this device never goes to the network', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.onDevice['k'] = await _png();
      expect(await service.load('http://s/k', 'k'), isNotNull);
      expect(source.downloads, isEmpty);
      expect(service.peek('k'), isNotNull);
    });
  });

  testWidgets(
    'a dropped connection doesn\'t go looking for a cover elsewhere',
    (tester) async {
      await tester.runAsync(() async {
        var lookups = 0;
        final image = await service.load(
          'http://s/k',
          'k',
          fallbackUrl: () async {
            lookups++;
            return null;
          },
        );
        expect(image, isNull);
        expect(lookups, 0);
      });
    },
  );

  testWidgets('a cover the server doesn\'t have is looked for elsewhere', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.notOnServer.add('k');
      var lookups = 0;
      await service.load(
        'http://s/k',
        'k',
        fallbackUrl: () async {
          lookups++;
          return null;
        },
      );
      expect(lookups, 1);
    });
  });

  testWidgets('a failed cover waits, unless the connection changes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      expect(await service.load('http://s/k', 'k'), isNull);
      expect(await service.load('http://s/k', 'k'), isNull);
      expect(source.downloads, hasLength(1));

      service.retryFailed();
      source.onServer['k'] = await _png();
      expect(await service.load('http://s/k', 'k'), isNotNull);
      expect(source.downloads, hasLength(2));
    });
  });

  testWidgets(
    'a replica placeholder does not suppress a repaired cover for an hour',
    (tester) async {
      await tester.runAsync(() async {
        source.temporarilyMissing.add('k');
        var fallbackCalls = 0;
        expect(
          await service.load(
            'http://s/k',
            'k',
            fallbackUrl: () async {
              fallbackCalls++;
              return 'http://external/guess';
            },
          ),
          isNull,
        );
        expect(fallbackCalls, 0);
        expect(service.isMissing('k'), isFalse);
        source.temporarilyMissing.clear();
        source.onServer['k'] = await _png();
        now = now.add(const Duration(seconds: 16));
        expect(await service.load('http://s/k', 'k'), isNotNull);
        expect(source.downloads, hasLength(2));
      });
    },
  );

  testWidgets('a failed cover is tried again after a while', (tester) async {
    await tester.runAsync(() async {
      expect(await service.load('http://s/k', 'k'), isNull);
      now = now.add(const Duration(minutes: 2));
      source.onServer['k'] = await _png();
      expect(await service.load('http://s/k', 'k'), isNotNull);
    });
  });

  testWidgets('a saved error message is replaced by the real cover', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.onDevice['k'] = Uint8List.fromList('{"error":"nope"}'.codeUnits);
      source.onServer['k'] = await _png();
      expect(await service.load('http://s/k', 'k'), isNotNull);
      expect(source.forgotten, ['k']);
    });
  });

  testWidgets('a request stuck on an old address is left behind', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.held['k'] = Completer();
      unawaited(service.load('http://old/k', 'k'));
      await Future<void>.delayed(Duration.zero);

      service.retryFailed();
      source.held.remove('k');
      source.onServer['k'] = await _png();
      expect(await service.load('http://new/k', 'k'), isNotNull);
    });
  });

  testWidgets('a cancelled request does not block its replacement', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final stuck = Completer<Uint8List>();
      source.held['k'] = stuck;
      final old = service.load('http://old/k', 'k');
      await Future<void>.delayed(Duration.zero);

      service.retryFailed();
      expect(source.cancels, 1);
      source.held.remove('k');
      source.onServer['k'] = await _png();
      stuck.completeError(Exception('cancelled'));
      expect(await old, isNull);
      expect(await service.load('http://new/k', 'k'), isNotNull);
    });
  });

  testWidgets('a real picture that will not decode is kept', (tester) async {
    await tester.runAsync(() async {
      // Starts like a JPEG but is cut off, as with a phone short of memory it fails.
      source.onDevice['k'] = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0, 0, 0]);
      expect(await service.load('http://s/k', 'k'), isNull);
      expect(source.forgotten, isEmpty);
    });
  });

  testWidgets('a cover the server has no picture for is not asked for again', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.notOnServer.add('k');
      expect(await service.load('http://s/k', 'k'), isNull);
      expect(service.isMissing('k'), isTrue);
      now = now.add(const Duration(minutes: 5));
      expect(await service.load('http://s/k', 'k'), isNull);
      expect(source.downloads, hasLength(1));

      now = now.add(const Duration(hours: 2));
      expect(service.isMissing('k'), isFalse);
      await service.load('http://s/k', 'k');
      expect(source.downloads, hasLength(2));
    });
  });

  testWidgets('a connection failure does not count as having no picture', (
    tester,
  ) async {
    await tester.runAsync(() async {
      expect(await service.load('http://s/k', 'k'), isNull);
      expect(service.isMissing('k'), isFalse);
    });
  });

  testWidgets('warming only reads this device and fills memory', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.onDevice['here'] = await _png();
      source.onServer['there'] = await _png();
      await service.warm(['here', 'there'], limit: const Duration(seconds: 5));
      expect(service.peek('here'), isNotNull);
      expect(service.peek('there'), isNull);
      expect(source.downloads, isEmpty);
      // Not having it on the device doesn't count as it having failed.
      expect(await service.load('http://s/there', 'there'), isNotNull);
    });
  });

  testWidgets('a load during warming still fetches what warming lacked', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.onServer['k'] = await _png();
      final warming = service.warm(['k'], limit: const Duration(seconds: 5));
      expect(await service.load('http://s/k', 'k'), isNotNull);
      await warming;
    });
  });

  testWidgets('memory can be released, and covers reload from this device', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.onDevice['k'] = await _png();
      await service.load('http://s/k', 'k');
      service.releaseMemory();
      expect(service.peek('k'), isNull);
      expect(await service.load('http://s/k', 'k'), isNotNull);
      expect(source.downloads, isEmpty);
    });
  });

  Widget cover(String id, {double size = 56}) =>
      ChangeNotifierProvider<SessionController>.value(
        value: FakeSession(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: CoverArt(coverArtId: id, size: size),
          ),
        ),
      );

  ui.Image? shown(WidgetTester tester) {
    final images = tester.widgetList<RawImage>(find.byType(RawImage));
    return images.isEmpty ? null : images.last.image;
  }

  String keyFor(String id) => coverCacheKey(id, smallCoverPx);

  testWidgets('a cover in memory shows on the first frame', (tester) async {
    await tester.runAsync(() async {
      source.onDevice[keyFor('a')] = await _png();
      await service.warm([keyFor('a')], limit: const Duration(seconds: 5));
    });
    await tester.pumpWidget(cover('a'));
    expect(shown(tester), same(service.peek(keyFor('a'))));
  });

  testWidgets(
    'legacy real art remains visible offline without hiding a new revision',
    (tester) async {
      final legacy = keyFor('mf-song');
      final revised = keyFor('mf-song_abcd1234');
      await tester.runAsync(() async {
        source.onDevice[legacy] = await _png();
        await service.warm([legacy], limit: const Duration(seconds: 5));
      });
      source.held[revised] = Completer();
      await tester.pumpWidget(cover('mf-song_abcd1234'));
      expect(shown(tester), same(service.peek(legacy)));
      expect(service.peek(revised), isNull);
      await tester.runAsync(() async {
        source.onDevice[revised] = await _png();
        await service.warm([revised], limit: const Duration(seconds: 5));
      });
      service.retryFailed();
      source.held[revised]!.completeError(Exception('old request canceled'));
      await tester.pumpAndSettle();
      expect(service.peek(revised), isNotNull);
      expect(shown(tester), same(service.peek(revised)));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a big cover shows the saved small one while it loads', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.onDevice[coverCacheKey('a', smallCoverPx)] = await _png();
    });
    final bigKey = coverCacheKey('a', largeCoverPx);
    source.held[bigKey] = Completer();
    await tester.pumpWidget(cover('a', size: 200));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(shown(tester), isNotNull);
    expect(source.downloads, [bigKey]);

    source.held[bigKey]!.completeError(Exception('no connection'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(
      shown(tester),
      isNotNull,
      reason: 'offline, small is better than none',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a reused row drops the previous cover straight away', (
    tester,
  ) async {
    await tester.runAsync(() async {
      source.onDevice[keyFor('a')] = await _png();
      await service.warm([keyFor('a')], limit: const Duration(seconds: 5));
    });
    source.held[keyFor('b')] = Completer();
    await tester.pumpWidget(cover('a'));
    expect(shown(tester), isNotNull);

    await tester.pumpWidget(cover('b'));
    expect(find.byType(RawImage), findsNothing);

    source.held[keyFor('b')]!.completeError(Exception('finished with this'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'a failed cover tries again by itself, with nothing else changing',
    (tester) async {
      Future<void> settleLoad() => tester.runAsync(() async {
        await service.load('http://s/a', keyFor('a'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });

      await tester.pumpWidget(cover('a'));
      await settleLoad();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);

      await tester.runAsync(() async {
        source.onServer[keyFor('a')] = await _png();
      });
      now = now.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 20));
      await settleLoad();
      await tester.pumpAndSettle();
      expect(shown(tester), isNotNull);
    },
  );

  testWidgets('a cover with no picture stays calm: no retries, no flicker', (
    tester,
  ) async {
    source.notOnServer.add(keyFor('a'));
    await tester.pumpWidget(cover('a'));
    await tester.runAsync(() async {
      await service.load('http://s/a', keyFor('a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    final asked = source.downloads.length;

    now = now.add(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 10));
    expect(source.downloads, hasLength(asked));
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
  });

  testWidgets('a retry keeps the fallback up instead of going blank', (
    tester,
  ) async {
    await tester.pumpWidget(cover('a'));
    await tester.runAsync(() async {
      await service.load('http://s/a', keyFor('a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();

    source.held[keyFor('a')] = Completer();
    now = now.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);

    source.held[keyFor('a')]!.completeError(Exception('still down'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a recently failed cover does not break building the screen', (
    tester,
  ) async {
    await tester.runAsync(() => service.load('http://s/a', keyFor('a')));
    await tester.pumpWidget(cover('a'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
  });

  testWidgets('a failed cover appears once the connection returns', (
    tester,
  ) async {
    await tester.pumpWidget(cover('a'));
    await tester.runAsync(() async {
      await service.load('http://s/a', keyFor('a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);

    await tester.runAsync(() async {
      source.onServer[keyFor('a')] = await _png();
      service.retryFailed();
      await service.load('http://s/a', keyFor('a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    expect(shown(tester), isNotNull);
  });
}
