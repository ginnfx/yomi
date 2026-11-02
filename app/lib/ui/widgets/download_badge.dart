import 'package:flutter/material.dart';

import '../../state/download_manager.dart';
import '../theme.dart';

/// Tiny status mark shown next to a song: saved, downloading, waiting, or failed.
class DownloadBadge extends StatelessWidget {
  const DownloadBadge({
    super.key,
    required this.status,
    this.progress = 0,
    this.size = 16,
  });

  final DownloadStatus status;
  final double progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case DownloadStatus.done:
        return Icon(
          Icons.arrow_circle_down_rounded,
          size: size,
          color: YomiColors.success,
        );
      case DownloadStatus.downloading:
        return SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            value: progress <= 0 ? null : progress,
            strokeWidth: 2,
            color: context.accent,
            backgroundColor: Colors.white12,
          ),
        );
      case DownloadStatus.queued:
        return Icon(
          Icons.schedule_rounded,
          size: size,
          color: YomiColors.textSecondary,
        );
      case DownloadStatus.failed:
        return Icon(
          Icons.error_outline_rounded,
          size: size,
          color: Colors.redAccent,
        );
      case DownloadStatus.none:
        return const SizedBox.shrink();
    }
  }
}
