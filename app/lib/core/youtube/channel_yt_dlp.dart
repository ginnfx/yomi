import 'dart:async';

import 'package:flutter/services.dart';

import 'yt_dlp.dart';

const Duration kYtDlpRunTimeout = Duration(minutes: 15);

/// yt-dlp behind a method channel: youtubedl-android on Android, YouTubeKit on iPhone.
class ChannelYtDlp implements YtDlp {
  ChannelYtDlp({this.runTimeout = kYtDlpRunTimeout}) {
    _channel.setMethodCallHandler(_onCall);
  }

  /// Longest a single run may take before it is given up on.
  final Duration runTimeout;

  static const _channel = MethodChannel('com.yomi.yomi/ytdlp');
  final Map<String, void Function(String line)> _listeners = {};
  int _jobs = 0;

  @override
  bool get isAvailable => true;

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'line') return;
    final args = call.arguments as Map<Object?, Object?>;
    final listener = _listeners[args['job']];
    final line = args['line'];
    if (listener != null && line is String) listener(line);
  }

  @override
  Future<String> run(
    List<String> args, {
    void Function(String line)? onLine,
  }) async {
    final job = 'job${_jobs++}';
    if (onLine != null) _listeners[job] = onLine;
    try {
      return await _channel
              .invokeMethod<String>('run', {'args': args, 'job': job})
              .timeout(runTimeout) ??
          '';
    } on TimeoutException {
      throw const YtDlpException('yt-dlp took too long');
    } on PlatformException catch (error) {
      throw YtDlpException(error.message ?? 'yt-dlp failed');
    } finally {
      _listeners.remove(job);
    }
  }

  @override
  Future<void> update() async {
    try {
      await _channel.invokeMethod<String>('update');
    } on PlatformException {
      // A failed update leaves the bundled copy, which still works for a while.
    }
  }
}
