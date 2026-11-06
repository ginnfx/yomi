import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'yt_dlp.dart';

const String _releases =
    'https://github.com/yt-dlp/yt-dlp/releases/latest/download';
const String _checksums = 'SHA2-256SUMS';
const Duration _downloadTimeout = Duration(minutes: 5);
const Duration _runTimeout = Duration(minutes: 5);

/// Starts a process; swapped out in tests.
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// The official standalone yt-dlp for macOS or Linux, fetched on first use into the
/// app's own folder and checked against the release's published SHA-256 sums.
class ProcessYtDlp implements YtDlp {
  ProcessYtDlp({
    required this.directory,
    required this.binaryName,
    http.Client? httpClient,
    ProcessStarter? start,
  }) : _http = httpClient ?? http.Client(),
       _start = start ?? Process.start;

  /// The binary for this computer, or null where there's no official one.
  static String? binaryFor(String operatingSystem) => switch (operatingSystem) {
    'macos' => 'yt-dlp_macos',
    'linux' => 'yt-dlp_linux',
    _ => null,
  };

  final Directory directory;
  final String binaryName;
  final http.Client _http;
  final ProcessStarter _start;
  Future<File>? _installing;

  File get _binary => File('${directory.path}/$binaryName');

  @override
  bool get isAvailable => true;

  Future<File> _ensureInstalled() {
    if (_binary.existsSync()) return Future.value(_binary);
    return _installing ??= _install().whenComplete(() => _installing = null);
  }

  Future<File> _install() async {
    await directory.create(recursive: true);
    final sums = await _get('$_releases/$_checksums');
    final expected = _expectedHash(utf8.decode(sums), binaryName);
    if (expected == null) {
      throw YtDlpException('The yt-dlp release lists no $binaryName');
    }
    final bytes = await _get('$_releases/$binaryName');
    if (sha256.convert(bytes).toString() != expected) {
      throw const YtDlpException(
        'The downloaded yt-dlp did not match its checksum',
      );
    }
    final temp = File('${_binary.path}.download');
    await temp.writeAsBytes(bytes, flush: true);
    final chmod = await Process.run('chmod', ['755', temp.path]);
    if (chmod.exitCode != 0) {
      throw YtDlpException('Could not make yt-dlp runnable: ${chmod.stderr}');
    }
    return temp.rename(_binary.path);
  }

  Future<List<int>> _get(String url) async {
    final response = await _http.get(Uri.parse(url)).timeout(_downloadTimeout);
    if (response.statusCode != 200) {
      throw YtDlpException('Getting yt-dlp answered ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  @override
  Future<String> run(
    List<String> args, {
    void Function(String line)? onLine,
  }) async {
    final binary = await _ensureInstalled();
    return runYtDlpProcess(_start, binary.path, args, onLine: onLine);
  }

  @override
  Future<void> update() async {
    if (!_binary.existsSync()) return;
    try {
      await run(['--ignore-config', '-U']);
    } on Exception catch (error) {
      debugPrint('yt-dlp update failed: $error');
    }
  }
}

/// Runs yt-dlp, streaming stdout lines; a failure carries its last error line.
Future<String> runYtDlpProcess(
  ProcessStarter start,
  String executable,
  List<String> args, {
  void Function(String line)? onLine,
}) async {
  final process = await start(executable, args);
  final out = StringBuffer();
  final err = StringBuffer();
  final reading = [
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          out.writeln(line);
          onLine?.call(line);
        }),
    process.stderr.transform(utf8.decoder).forEach(err.write),
  ];
  final code = await process.exitCode.timeout(
    _runTimeout,
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  await Future.wait(reading);
  if (code != 0) {
    throw YtDlpException(_lastLine(err.toString()) ?? 'yt-dlp stopped ($code)');
  }
  return out.toString();
}

/// The hash listed for [name] in a SHA2-256SUMS file.
String? _expectedHash(String sums, String name) {
  for (final line in const LineSplitter().convert(sums)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length == 2 && parts[1] == name) return parts[0].toLowerCase();
  }
  return null;
}

String? _lastLine(String text) {
  final lines = const LineSplitter()
      .convert(text)
      .where((line) => line.trim().isNotEmpty)
      .toList();
  return lines.isEmpty ? null : lines.last.trim();
}

@visibleForTesting
String? expectedHashFor(String sums, String name) => _expectedHash(sums, name);
