import 'dart:io';

import '../server_pool.dart';
import 'file_fetcher.dart';

/// A [FileFetcher] that spreads transfers over every healthy server. The caller's address
/// names one server; this tries the best-ranked server first and, if it fails, the next,
/// so a replica that lacks a file or has just gone offline never fails the download.
class PooledFetcher implements FileFetcher {
  PooledFetcher({
    required this.pool,
    FileFetcher inner = const FileFetcher(),
    DateTime Function()? now,
  }) : _inner = inner,
       _now = now ?? DateTime.now;

  final ServerPool pool;
  final FileFetcher _inner;
  final DateTime Function() _now;

  @override
  Future<FetchedFile> fetch(
    Uri uri,
    File base, {
    void Function(double progress)? onProgress,
    CancelToken? cancel,
  }) async {
    final servers = pool.rank();
    if (servers.isEmpty) {
      return _inner.fetch(uri, base, onProgress: onProgress, cancel: cancel);
    }
    Object? lastError;
    for (final server in servers) {
      if (cancel?.isCancelled ?? false) throw const FetchCancelled();
      final release = pool.lease(server);
      final started = _now();
      try {
        final fetched = await _inner.fetch(
          rebaseOnServer(uri, pool.resolve(server)),
          base,
          onProgress: onProgress,
          cancel: cancel,
        );
        pool.recordSuccess(server, _now().difference(started));
        return fetched;
      } on FetchCancelled {
        rethrow;
      } on FetchFailed catch (error) {
        pool.recordFailure(server);
        lastError = error;
      } finally {
        release();
      }
    }
    throw lastError! as FetchFailed;
  }
}
