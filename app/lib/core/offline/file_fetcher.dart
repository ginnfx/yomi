import 'dart:io';

import 'audio_files.dart';

const Duration _connectTimeout = Duration(seconds: 15);
const Duration _stallTimeout = Duration(seconds: 30);

class FetchCancelled implements Exception {
  const FetchCancelled();

  @override
  String toString() => 'Download cancelled.';
}

class FetchFailed implements Exception {
  const FetchFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Lets a caller stop an in-flight fetch.
class CancelToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

class FetchedFile {
  const FetchedFile(this.file, this.bytes);

  final File file;
  final int bytes;
}

/// Downloads a song into a file. The data goes to a temporary file first; only when it is
/// complete is it renamed to `<base>.<real type>`, so a half-finished file can never be
/// mistaken for a song and the extension always matches the content.
class FileFetcher {
  const FileFetcher();

  /// [base] is the target path *without* an extension.
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    void Function(double progress)? onProgress,
    CancelToken? cancel,
  }) async {
    await base.parent.create(recursive: true);
    final temp = File('${base.path}.dl');
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    IOSink? sink;
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(_connectTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw FetchFailed('Server answered ${response.statusCode}.');
      }
      final contentType = response.headers.contentType?.mimeType ?? '';
      if (!contentType.startsWith('audio/') &&
          contentType != 'application/octet-stream') {
        await response.drain<void>();
        throw const FetchFailed('The server did not send an audio file.');
      }
      final expected = response.contentLength;
      sink = temp.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(_stallTimeout)) {
        if (cancel?.isCancelled ?? false) throw const FetchCancelled();
        sink.add(chunk);
        received += chunk.length;
        if (expected > 0) onProgress?.call(received / expected);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (expected > 0 && received != expected)
        throw const FetchFailed('The download was cut short.');
      if (received == 0)
        throw const FetchFailed('The server sent an empty file.');
      final extension = await sniffFile(temp);
      if (extension == null)
        throw const FetchFailed('The file is not a recognised audio format.');
      final target = File('${base.path}.$extension');
      await _removeOtherCopies(base, keep: target);
      await temp.rename(target.path);
      onProgress?.call(1);
      return FetchedFile(target, received);
    } on SocketException {
      throw const FetchFailed('Cannot reach the server.');
    } on HttpException catch (error) {
      throw FetchFailed('Connection problem: ${error.message}');
    } finally {
      await sink?.close().catchError((Object _) {});
      client.close(force: true);
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _removeOtherCopies(File base, {required File keep}) async {
    for (final ext in audioExtensions) {
      final other = File('${base.path}.$ext');
      if (other.path != keep.path && await other.exists()) await other.delete();
    }
  }
}
