import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/download_manager.dart';

/// Saves [songs] to this device, or removes them when [isFullySaved], and says which.
Future<void> toggleSongsDownload(
  BuildContext context,
  List<Song> songs, {
  required bool isFullySaved,
}) async {
  HapticFeedback.selectionClick();
  final downloads = context.read<DownloadManager>();
  final messenger = ScaffoldMessenger.of(context);
  if (isFullySaved) {
    for (final song in songs) {
      await downloads.remove(song);
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Removed from this device')),
    );
    return;
  }
  final missing = songs.length - downloads.downloadedCountOf(songs);
  downloads.enqueue(songs);
  messenger.showSnackBar(
    SnackBar(
      content: Text(downloads.pausedReason ?? 'Downloading $missing songs…'),
    ),
  );
}

/// Whether any of [songs] is waiting for, or in the middle of, being saved.
bool isAnyDownloading(DownloadManager downloads, List<Song> songs) =>
    songs.any((song) {
      final status = downloads.statusOf(song.id);
      return status == DownloadStatus.queued ||
          status == DownloadStatus.downloading;
    });
