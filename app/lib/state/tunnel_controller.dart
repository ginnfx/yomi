import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/tunnel/tunnel_bridge.dart';
import '../core/upload/bulk_upload_api.dart';

const int _musicPort = 4533;
const String _hostKey = 'tunnel.serverHost';
const String _deviceKey = 'tunnel.deviceId';
const String _runningState = 'Running';
const String _invitePrefix = 'tskey-auth-';

/// The code wasn't accepted, or the tunnel couldn't start. [message] is for the user.
class TunnelException implements Exception {
  const TunnelException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Lets a device reach the server with only an invite code. The code is used once to join
/// and never saved; after that the node's own key, kept in [stateDir], is what connects.
class TunnelController extends ChangeNotifier {
  TunnelController({
    required this.bridge,
    required this.prefs,
    required this.stateDir,
  });

  final TunnelBridge bridge;
  final SharedPreferences prefs;
  final Directory stateDir;
  final Map<String, String> _forwards = {};
  final Map<String, int> _uploadPorts = {};
  String? _musicUrl;
  int? _uploadPort;
  Future<void> _pending = Future<void>.value();

  // Joining, restarting and leaving must not stop one another mid-operation.
  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> networkChanged() => _serialize(() async {
    try {
      await bridge.networkChanged();
    } on Exception catch (error) {
      debugPrint('Tunnel network notification failed: $error');
    }
  });

  Future<String?> reconnect() => _serialize(() => _connect(restart: true));

  /// Whether this device has joined and can connect by itself.
  bool get isEnrolled => prefs.containsKey(_hostKey);

  /// The loopback address of the server while the tunnel is up.
  String? get musicUrl => _musicUrl;
  bool isTunnelUrl(String url) => url == _musicUrl;

  /// The upload service's port for [url], when that differs from the usual one.
  int uploadPortFor(String url) =>
      _uploadPorts[url] ??
      (isTunnelUrl(url) ? (_uploadPort ?? uploadPort) : uploadPort);

  /// Resolve a tailnet address through this app's node, never the system VPN.
  Future<String?> resolve(String url) => _serialize(() async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'http' ||
        !(uri.host.startsWith('100.') || uri.host.endsWith('.ts.net')))
      return null;
    if (await _connect() == null) return null;
    final cached = _forwards[url];
    if (cached != null) return cached;
    try {
      final music = await bridge.forward('${uri.host}:${uri.port}');
      final upload = await bridge.forward('${uri.host}:$uploadPort');
      final local = uri.replace(host: '127.0.0.1', port: music).toString();
      _forwards[url] = local;
      _uploadPorts[local] = upload;
      return local;
    } on Exception {
      return null;
    }
  });

  String get _hostname {
    var id = prefs.getString(_deviceKey);
    if (id == null) {
      final random = Random.secure();
      id = List.generate(6, (_) => random.nextInt(16).toRadixString(16)).join();
      prefs.setString(_deviceKey, id);
    }
    return 'yomi-$id';
  }

  /// Joins using an invite code. [serverHost] is the server's Tailscale address.
  Future<void> join(String code, String serverHost) => _serialize(() async {
    final trimmed = code.trim();
    if (!trimmed.startsWith(_invitePrefix)) {
      throw const TunnelException("That doesn't look like an invite code.");
    }
    if (serverHost.isEmpty) {
      throw const TunnelException('Enter the server address first.');
    }
    await _start(authKey: trimmed, serverHost: serverHost);
    await prefs.setString(_hostKey, serverHost);
    notifyListeners();
  });

  /// Returns the server's loopback address, starting the tunnel if needed. Null when this
  /// device hasn't joined or the tunnel can't start right now.
  Future<String?> connect() => _serialize(() => _connect());

  Future<String?> _connect({bool restart = false}) async {
    final host = prefs.getString(_hostKey);
    if (host == null) return null;
    try {
      final current = _musicUrl;
      if (!restart &&
          current != null &&
          await bridge.state() == _runningState) {
        return current;
      }
      // Phones can suspend the node, so anything but a healthy state starts over.
      _forwards.clear();
      _uploadPorts.clear();
      await bridge.stop();
      await _start(authKey: '', serverHost: host);
      return _musicUrl;
    } on Exception catch (error) {
      _musicUrl = null;
      _uploadPort = null;
      debugPrint('Tunnel unavailable: $error');
      return null;
    }
  }

  Future<void> _start({
    required String authKey,
    required String serverHost,
  }) async {
    try {
      await stateDir.create(recursive: true);
      await bridge.start(
        stateDir: stateDir.path,
        authKey: authKey,
        hostname: _hostname,
      );
      final music = await bridge.forward('$serverHost:$_musicPort');
      final upload = await bridge.forward('$serverHost:$uploadPort');
      _musicUrl = 'http://127.0.0.1:$music';
      _uploadPort = upload;
    } on PlatformException catch (error) {
      debugPrint('Tunnel failed: ${error.code} ${error.message}');
      _musicUrl = null;
      _uploadPort = null;
      throw const TunnelException(
        "Couldn't connect with that code. It may be used or expired.",
      );
    } on MissingPluginException {
      throw const TunnelException('Invites are not available on this device.');
    }
  }

  /// Leaves the tailnet on this device. It needs a new invite to come back.
  Future<void> leave() => _serialize(() async {
    try {
      _forwards.clear();
      _uploadPorts.clear();
      await bridge.stop();
    } on PlatformException catch (error) {
      debugPrint('Tunnel stop failed: ${error.message}');
    }
    _musicUrl = null;
    _uploadPort = null;
    await prefs.remove(_hostKey);
    if (await stateDir.exists()) await stateDir.delete(recursive: true);
    notifyListeners();
  });
}
