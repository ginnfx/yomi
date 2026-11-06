import 'package:flutter/services.dart';

/// The native Tailscale node. A separate type so it can be faked in tests.
abstract interface class TunnelBridge {
  Future<void> start({
    required String stateDir,
    required String authKey,
    required String hostname,
  });

  /// Opens a loopback port reaching [remote] ("host:port") and returns the port.
  Future<int> forward(String remote);
  Future<String> state();
  Future<void> networkChanged();
  Future<void> stop();
}

class MethodChannelTunnelBridge implements TunnelBridge {
  const MethodChannelTunnelBridge();

  static const _channel = MethodChannel('com.yomi.yomi/tunnel');

  @override
  Future<void> start({
    required String stateDir,
    required String authKey,
    required String hostname,
  }) => _channel.invokeMethod<void>('start', {
    'stateDir': stateDir,
    'authKey': authKey,
    'hostname': hostname,
  });

  @override
  Future<int> forward(String remote) async {
    final port = await _channel.invokeMethod<int>('forward', {
      'remote': remote,
    });
    if (port == null) throw PlatformException(code: 'no_port');
    return port;
  }

  @override
  Future<String> state() async =>
      await _channel.invokeMethod<String>('state') ?? 'NoState';

  @override
  Future<void> networkChanged() =>
      _channel.invokeMethod<void>('networkChanged');

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');
}
