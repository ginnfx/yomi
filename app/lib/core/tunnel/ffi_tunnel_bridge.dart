import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'tunnel_bridge.dart';

/// The library tailscale_bridge/build.sh linux makes, installed next to the app.
const String kTunnelLibraryName = 'libtailscale_bridge.so';

typedef _StartNative = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _ForwardNative = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _ForwardDart = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _TextNative = Pointer<Utf8> Function();
typedef _VoidNative = Void Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// Where the Linux app keeps the tunnel library: the bundle's lib folder.
String tunnelLibraryPath() =>
    '${File(Platform.resolvedExecutable).parent.path}/lib/$kTunnelLibraryName';

/// The tunnel for this device: the C library on Linux, the platform channel elsewhere.
TunnelBridge tunnelBridgeForThisDevice() {
  if (!Platform.isLinux) return const MethodChannelTunnelBridge();
  final path = tunnelLibraryPath();
  return File(path).existsSync()
      ? FfiTunnelBridge(path)
      : const MethodChannelTunnelBridge();
}

/// The embedded Tailscale node on Linux, called through dart:ffi. Slow calls run on a
/// background isolate so the app keeps drawing while the tunnel connects.
class FfiTunnelBridge implements TunnelBridge {
  const FfiTunnelBridge(this.libraryPath);

  final String libraryPath;

  @override
  Future<void> start({
    required String stateDir,
    required String authKey,
    required String hostname,
  }) async {
    final path = libraryPath;
    final error = await Isolate.run(() {
      final library = _Library(path);
      final args = [stateDir, authKey, hostname].map((s) => s.toNativeUtf8());
      final [dir, key, host] = args.toList();
      try {
        return library.takeText(library.start(dir, key, host));
      } finally {
        for (final arg in [dir, key, host]) {
          malloc.free(arg);
        }
      }
    });
    if (error != null) throw PlatformException(code: 'start', message: error);
  }

  @override
  Future<int> forward(String remote) async {
    final path = libraryPath;
    final (port, error) = await Isolate.run(() {
      final library = _Library(path);
      final address = remote.toNativeUtf8();
      final errorOut = malloc<Pointer<Utf8>>()..value = nullptr;
      try {
        final port = library.forward(address, errorOut);
        return (port, library.takeText(errorOut.value));
      } finally {
        malloc
          ..free(address)
          ..free(errorOut);
      }
    });
    if (port < 0) throw PlatformException(code: 'forward', message: error);
    return port;
  }

  @override
  Future<String> state() async {
    final library = _Library(libraryPath);
    return library.takeText(library.state()) ?? 'NoState';
  }

  @override
  Future<void> networkChanged() async => _Library(libraryPath).networkChanged();

  @override
  Future<void> stop() async {
    final path = libraryPath;
    final error = await Isolate.run(() {
      final library = _Library(path);
      return library.takeText(library.stop());
    });
    if (error != null) throw PlatformException(code: 'stop', message: error);
  }
}

/// The library's functions. Opening it again in another isolate returns the same copy,
/// so the Go side keeps one tunnel for the whole app.
class _Library {
  _Library(String path) {
    final library = DynamicLibrary.open(path);
    start = library.lookupFunction<_StartNative, _StartNative>(
      'YomiTunnelStart',
    );
    forward = library.lookupFunction<_ForwardNative, _ForwardDart>(
      'YomiTunnelForward',
    );
    state = library.lookupFunction<_TextNative, _TextNative>('YomiTunnelState');
    stop = library.lookupFunction<_TextNative, _TextNative>('YomiTunnelStop');
    networkChanged = library.lookupFunction<_VoidNative, void Function()>(
      'YomiTunnelNetworkChanged',
    );
    _free = library.lookupFunction<_FreeNative, _FreeDart>('YomiTunnelFree');
  }

  late final _StartNative start;
  late final _ForwardDart forward;
  late final _TextNative state;
  late final _TextNative stop;
  late final void Function() networkChanged;
  late final _FreeDart _free;

  /// Copies a string the library returned and frees it; null stays null.
  String? takeText(Pointer<Utf8> text) {
    if (text == nullptr) return null;
    try {
      return text.toDartString();
    } finally {
      _free(text);
    }
  }
}
