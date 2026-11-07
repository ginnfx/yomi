import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef DeviceRegistrar = Future<bool> Function({
  required String token,
  required String kind,
});

/// Asks the phone for its Apple push token and passes it to the Yomi server, so
/// messages reach the phone even when Yomi is closed. iPhone only for now.
class PushRegistration {
  PushRegistration({
    required this.register,
    MethodChannel? channel,
    bool? isSupported,
  }) : _channel = channel ?? const MethodChannel('yomi/push'),
       isSupported = isSupported ?? Platform.isIOS;

  final DeviceRegistrar register;
  final MethodChannel _channel;
  final bool isSupported;

  ({String token, String kind})? _device;
  bool _canRegister = false;
  String? _sentToken;

  void start() {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'token') return;
      final arguments = call.arguments;
      if (arguments is! Map) return;
      final token = arguments['token'];
      final environment = arguments['environment'];
      if (token is! String || token.isEmpty) return;
      _device = (
        token: token,
        kind: environment == 'sandbox' ? 'apns-sandbox' : 'apns',
      );
      _sentToken = null;
      await _send();
    });
  }

  /// Call once notifications are allowed. Registers with Apple, and with the
  /// server whenever it is reachable.
  Future<void> activate() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('register');
    } on PlatformException catch (error) {
      debugPrint('Could not register for push: $error');
    }
  }

  /// A server became reachable (sign-in, or switching servers).
  Future<void> serverReady() async {
    if (!_canRegister) _sentToken = null;
    _canRegister = true;
    await _send();
  }

  void serverGone() {
    _canRegister = false;
  }

  Future<void> _send() async {
    final device = _device;
    if (device == null || !_canRegister || _sentToken == device.token) return;
    final isDone = await register(token: device.token, kind: device.kind);
    if (isDone) _sentToken = device.token;
  }
}
