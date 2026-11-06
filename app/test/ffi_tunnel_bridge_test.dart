import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/tunnel/ffi_tunnel_bridge.dart';

/// Runs against a real build of the tunnel library:
///   go build -buildmode=c-shared -o /tmp/libtb.so ./cshared   (in tailscale_bridge)
///   YOMI_TUNNEL_LIB=/tmp/libtb.so flutter test test/ffi_tunnel_bridge_test.dart
void main() {
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
