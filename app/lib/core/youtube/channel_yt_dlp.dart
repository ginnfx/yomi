import 'dart:async';

import 'package:flutter/services.dart';

import 'yt_dlp.dart';

/// yt-dlp on Android, run by youtubedl-android behind a method channel.
class ChannelYtDlp implements YtDlp {
  ChannelYtDlp() {
    _channel.setMethodCallHandler(_onCall);
  }

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
      return await _channel.invokeMethod<String>('run', {
            'args': args,
            'job': job,
          }) ??
          '';
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
