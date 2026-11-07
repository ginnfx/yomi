import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef DeviceRegistrar = Future<bool> Function({
  required String token,
  required String kind,
});

/// Asks the phone for its Apple push token and passes it to the Yomi server, so
/// messages reach the phone even when Yomi is closed (Apple on iPhone, Firebase on
/// Android).
class PushRegistration {
  PushRegistration({
    required this.register,
    required this.unregister,
    this.isEnabled = true,
    SharedPreferences? prefs,
    MethodChannel? channel,
    bool? isSupported,
  }) : _prefs = prefs,
       _channel = channel ?? const MethodChannel('yomi/push'),
       isSupported = isSupported ?? (Platform.isIOS || Platform.isAndroid);

  final SharedPreferences? _prefs;
  final DeviceRegistrar register;
  final DeviceRegistrar unregister;
  bool isEnabled;
  Future<void> _pending = Future.value();
  ({String token, String kind})? _registeredDevice;
  final MethodChannel _channel;
  final bool isSupported;

  ({String token, String kind})? _device;
  bool _canRegister = false;
  String? _sentToken;

  /// Whether the server has this phone's token, so it will push by itself.
  bool get isRegistered => _sentToken != null;

  void start() {
    if (!isSupported) return;
    final savedToken = _prefs?.getString('pushDeviceToken');
    final savedKind = _prefs?.getString('pushDeviceKind');
    if (savedToken != null && savedKind != null) {
      _device = (token: savedToken, kind: savedKind);
      _registeredDevice = (
        token: _prefs?.getString('pushRegisteredToken') ?? savedToken,
        kind: _prefs?.getString('pushRegisteredKind') ?? savedKind,
      );
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'token') return;
      final arguments = call.arguments;
      if (arguments is! Map) return;
      final token = arguments['token'];
      final environment = arguments['environment'];
      if (token is! String || token.isEmpty) return;
      _device = (
        token: token,
        kind: switch (environment) {
          'sandbox' => 'apns-sandbox',
          'android' => 'fcm',
          _ => 'apns',
        },
      );
      await _prefs?.setString('pushDeviceToken', _device!.token);
      await _prefs?.setString('pushDeviceKind', _device!.kind);
      _sentToken = null;
      await _send();
    });
  }

  /// Call once notifications are allowed. Registers with Apple, and with the
  /// server whenever it is reachable.
  Future<void> activate() async {
    if (!isSupported || !isEnabled) return;
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

  /// Applies the user's preference and removes any server registration before returning.
  Future<void> setEnabled(bool enabled) {
    isEnabled = enabled;
    return _send();
  }

  Future<void> deactivate() => setEnabled(false);

  Future<void> _send() {
    final next = _pending.then((_) => _reconcile());
    _pending = next.then<void>(
      (_) {},
      onError: (Object error) {
        debugPrint('Could not update push registration: $error');
      },
    );
    return _pending;
  }

  Future<void> _reconcile() async {
    if (!isEnabled) {
      final registered = _registeredDevice ?? _device;
      if (registered != null &&
          _canRegister &&
          await unregister(token: registered.token, kind: registered.kind)) {
        _registeredDevice = null;
        await _prefs?.remove('pushRegisteredToken');
        await _prefs?.remove('pushRegisteredKind');
        _sentToken = null;
      }
      return;
    }
    final device = _device;
    final old = _registeredDevice;
    if (old != null && device != null && old != device && _canRegister) {
      if (!await unregister(token: old.token, kind: old.kind)) return;
      _registeredDevice = null;
      await _prefs?.remove('pushRegisteredToken');
      await _prefs?.remove('pushRegisteredKind');
      _sentToken = null;
    }
    if (device == null || !_canRegister || _sentToken == device.token) return;
    final isDone = await register(token: device.token, kind: device.kind);
    if (isDone) {
      _sentToken = device.token;
      _registeredDevice = device;
      await _prefs?.setString('pushRegisteredToken', device.token);
      await _prefs?.setString('pushRegisteredKind', device.kind);
    }
  }
}
