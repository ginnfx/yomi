import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/tunnel/ffi_tunnel_bridge.dart';

/// A second of native work at 10 ms ticks would give ~100; even a loaded runner
/// manages far more than this, and a blocked isolate manages none.
const int _minTicks = 10;

/// Runs against a real build of the tunnel library:
///   go build -buildmode=c-shared -o /tmp/libtb.so ./cshared   (in tailscale_bridge)
///   YOMI_TUNNEL_LIB=/tmp/libtb.so flutter test test/ffi_tunnel_bridge_test.dart
void main() {
  test('a slow native status request leaves the UI isolate responsive', () async {
    final directory = await Directory.systemTemp.createTemp('yomi-ffi-status-');
    try {
      final source = File('${directory.path}/slow.c');
      await source.writeAsString(r'''
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
char *YomiTunnelStart(char *dir, char *key, char *host) { return NULL; }
int YomiTunnelForward(char *remote, char **error) { return 1; }
char *YomiTunnelState(void) { usleep(1000000); return strdup("NoState"); }
char *YomiTunnelStop(void) { return NULL; }
void YomiTunnelNetworkChanged(void) { usleep(1000000); }
void YomiTunnelFree(char *text) { free(text); }
''');
      final library =
          '${directory.path}/slow.${Platform.isMacOS ? 'dylib' : 'so'}';
      final compile = await Process.run('cc', [
        Platform.isMacOS ? '-dynamiclib' : '-shared',
        '-fPIC',
        source.path,
        '-o',
        library,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final bridge = FfiTunnelBridge(library);
      // A blocked UI isolate can't run its timers at all, while a busy runner
      // only delays them, so count ticks over the second the call takes instead
      // of racing one short timer.
      Future<int> ticksWhile(Future<void> call) async {
        var ticks = 0;
        final ticker = Timer.periodic(
          const Duration(milliseconds: 10),
          (_) => ticks++,
        );
        await call;
        ticker.cancel();
        return ticks;
      }

      late String state;
      final stateTicks = await ticksWhile(
        bridge.state().then((value) => state = value),
      );
      expect(state, 'NoState');
      expect(
        stateTicks,
        greaterThanOrEqualTo(_minTicks),
        reason: 'native status must not block UI timers',
      );
      final networkTicks = await ticksWhile(bridge.networkChanged());
      expect(
        networkTicks,
        greaterThanOrEqualTo(_minTicks),
        reason: 'a network change must not block UI timers',
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS && !Platform.isLinux);

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
