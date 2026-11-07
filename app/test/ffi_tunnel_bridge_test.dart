import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/tunnel/ffi_tunnel_bridge.dart';

const String _threadLibrarySource = r'''
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
char *YomiTunnelStart(char *dir, char *key, char *host) { return NULL; }
int YomiTunnelForward(char *remote, char **error) { return 1; }
char *YomiTunnelState(void) {
  char text[32];
  snprintf(text, sizeof text, "%lu", (unsigned long)pthread_self());
  return strdup(text);
}
char *YomiTunnelStop(void) { return NULL; }
static unsigned long lastNetworkThread;
void YomiTunnelNetworkChanged(void) { lastNetworkThread = (unsigned long)pthread_self(); }
void YomiTunnelFree(char *text) { free(text); }
unsigned long TestThreadNow(void) { return (unsigned long)pthread_self(); }
unsigned long TestLastNetworkThread(void) { return lastNetworkThread; }
''';

/// Runs against a real build of the tunnel library:
///   go build -buildmode=c-shared -o /tmp/libtb.so ./cshared   (in tailscale_bridge)
///   YOMI_TUNNEL_LIB=/tmp/libtb.so flutter test test/ffi_tunnel_bridge_test.dart
void main() {
  // The point of the isolates is that a slow native call never holds up the UI.
  // A timer can't show that reliably: Flutter's Linux test runner lets a blocking
  // native call in another isolate starve the test isolate's timers, which the real
  // app doesn't do. What can be checked everywhere is where the call runs: the
  // library reports the thread it was called on, and it must not be this one.
  test(
    'native status and network calls run off the UI isolate thread',
    () async {
      final directory = await Directory.systemTemp.createTemp('yomi-ffi-');
      try {
        final source = File('${directory.path}/threads.c');
        await source.writeAsString(_threadLibrarySource);
        final library =
            '${directory.path}/threads.${Platform.isMacOS ? 'dylib' : 'so'}';
        final compile = await Process.run('cc', [
          Platform.isMacOS ? '-dynamiclib' : '-shared',
          '-fPIC',
          source.path,
          '-o',
          library,
        ]);
        expect(compile.exitCode, 0, reason: '${compile.stderr}');
        final native = DynamicLibrary.open(library);
        final here = native
            .lookupFunction<UnsignedLong Function(), int Function()>(
              'TestThreadNow',
            )();
        final lastNetwork = native
            .lookupFunction<UnsignedLong Function(), int Function()>(
              'TestLastNetworkThread',
            );
        final bridge = FfiTunnelBridge(library);

        final stateThread = int.parse(await bridge.state());
        await bridge.networkChanged();

        expect(
          stateThread,
          isNot(here),
          reason: 'state() ran on the UI thread',
        );
        expect(lastNetwork(), isNot(0), reason: 'networkChanged() never ran');
        expect(
          lastNetwork(),
          isNot(here),
          reason: 'networkChanged() ran on the UI thread',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );

  final path = Platform.environment['YOMI_TUNNEL_LIB'];
  final skip = path == null ? 'set YOMI_TUNNEL_LIB to a built library' : false;

  test('reports no state before it starts', () async {
    // Act
    final state = await FfiTunnelBridge(path!).state();

    // Assert
    expect(state, 'NoState');
  }, skip: skip);

  test('forwarding before starting fails with the reason', () async {
    // Act / Assert
    await expectLater(
      FfiTunnelBridge(path!).forward('100.64.0.1:4533'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.message,
          'message',
          isNotEmpty,
        ),
      ),
    );
  }, skip: skip);

  test('stopping before starting is harmless', () async {
    // Act / Assert
    await FfiTunnelBridge(path!).stop();
  }, skip: skip);
}
