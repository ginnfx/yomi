import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/release_notes.dart';
import '../../state/update_controller.dart';
import '../theme.dart';
import 'release_notes_sheet.dart';

/// Small banner shown when a newer Yomi is out, then through download and install.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<UpdateController>();
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: updates.phase == UpdatePhase.idle
          ? const SizedBox(width: double.infinity)
          : _BannerBody(updates: updates),
    );
  }
}

class _BannerBody extends StatelessWidget {
  const _BannerBody({required this.updates});

  final UpdateController updates;

  String get _title => switch (updates.phase) {
    UpdatePhase.downloading => _downloadingTitle,
    UpdatePhase.installing => 'Installing update…',
    UpdatePhase.readyToInstall => 'Update ready to install',
    UpdatePhase.failed => updates.errorMessage ?? "The update couldn't finish.",
    _ => 'Yomi ${updates.release?.version} is available',
  };

  String get _downloadingTitle {
    final progress = updates.progress;
    return progress == null
        ? 'Downloading update'
        : 'Downloading update · ${(progress * 100).floor()}%';
  }

  /// The first line of the release notes, while there is an update to read about.
  String get _preview => updates.phase == UpdatePhase.available
      ? releaseNotePreview(updates.release?.notes ?? '')
      : '';

  String? get _actionLabel => switch (updates.phase) {
    UpdatePhase.downloading ||
    UpdatePhase.installing ||
    UpdatePhase.idle => null,
    UpdatePhase.readyToInstall => 'Install',
    UpdatePhase.failed => 'Retry',
    UpdatePhase.available =>
      updates.mode == UpdateMode.openReleasePage
          ? 'Download'
          : updates.isDesktopInstall
          ? 'Update & restart'
          : 'Update',
  };

  @override
  Widget build(BuildContext context) {
    final isDownloading = updates.phase == UpdatePhase.downloading;
    final isBusy = isDownloading || updates.phase == UpdatePhase.installing;
    final label = _actionLabel;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: YomiColors.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _showDetails(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title,
                          style: yomiText(
                            13,
                            weight: FontWeight.w600,
                            color: YomiColors.textPrimary,
                          ),
                        ),
                        if (_preview.isNotEmpty)
                          Text(
                            '$_preview · What\'s new',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: yomiText(
                              12,
                              weight: FontWeight.w500,
                              color: YomiColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (label != null)
                TextButton(
                  onPressed: () => unawaited(updates.startUpdate()),
                  child: Text(label),
                ),
              if (!isBusy)
                IconButton(
                  tooltip: 'Not now',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => unawaited(updates.dismiss()),
                ),
            ],
          ),
          if (isDownloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 10, 8),
              child: LinearProgressIndicator(value: updates.progress),
            ),
        ],
      ),
    );
  }

  void _showDetails(BuildContext context) {
    final release = updates.release;
    if (release == null) return;
    unawaited(showReleaseNotes(context, release));
  }
}
