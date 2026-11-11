import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/time_left.dart';
import '../../state/upload_queue.dart';
import '../theme.dart';
import '../widgets/missing_songs_section.dart';
import '../widgets/request_song_section.dart';
import '../widgets/wanted_songs_section.dart';

String _pauseMessage(UploadPause pause) => switch (pause) {
  UploadPause.waitingForServer =>
    "Can't reach the server. Trying again automatically.",
  UploadPause.signInAgain =>
    'Your login was refused. Sign in again to continue.',
  UploadPause.storageFull => "The server's storage is full.",
  UploadPause.needsFolderAccess =>
    'Yomi lost access to these files. Choose the folder again to continue.',
  UploadPause.onBackupServer =>
    "You're on the backup server. Uploads continue when the main one is back.",
  UploadPause.serverNeedsUpdate =>
    'The server needs updating before it can take bulk uploads.',
};

/// Adds music in bulk. Identical files are never sent, and anything that merely
/// looks like a duplicate waits for a decision. Nothing is ever deleted.
class UploadPage extends StatelessWidget {
  const UploadPage({super.key});

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<UploadQueue>();
    final items = queue.items;
    final likely = [
      for (final item in items)
        if (item.state == UploadState.likelyDuplicate) item,
    ];
    final bottom = MediaQuery.paddingOf(context).bottom;
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            sliver: SliverList.list(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    top: YomiSpace.l,
                    bottom: YomiSpace.l,
                  ),
                  child: Text(
                    'Add songs',
                    style: yomiText(
                      24,
                      weight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const _PickButtons(),
                if (items.isEmpty) ...[
                  const SizedBox(height: YomiSpace.l),
                  Text(
                    'No uploads queued',
                    style: yomiText(14, color: YomiColors.textSecondary),
                  ),
                ],
                if (queue.pause != null) ...[
                  const SizedBox(height: YomiSpace.l),
                  _PauseNotice(pause: queue.pause!),
                ],
                if (items.isNotEmpty) ...[
                  const SizedBox(height: YomiSpace.xl),
                  _Summary(queue: queue),
                ],
                if (likely.isNotEmpty) ...[
                  const SizedBox(height: YomiSpace.xl),
                  _LikelyHeader(count: likely.length),
                ],
              ],
            ),
          ),
          const SliverToBoxAdapter(child: RequestSongSection()),
          const SliverToBoxAdapter(child: MissingSongsSection()),
          const SliverToBoxAdapter(child: WantedSongsSection()),
          if (likely.isNotEmpty)
            SliverList.builder(
              itemCount: likely.length,
              itemBuilder: (_, i) => _LikelyRow(item: likely[i]),
            ),
          if (items.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                YomiSpace.xl,
                kPagePadding,
                YomiSpace.s,
              ),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'All files',
                  style: yomiText(16, weight: FontWeight.w800),
                ),
              ),
            ),
          SliverList.builder(
            itemCount: items.length,
            itemBuilder: (_, i) => _UploadRow(item: items[i]),
          ),
          SliverToBoxAdapter(child: SizedBox(height: bottom + YomiSpace.xl)),
        ],
      ),
    );
  }
}

class _PickButtons extends StatelessWidget {
  const _PickButtons();

  Future<void> _pickFolder(BuildContext context) async {
    final queue = context.read<UploadQueue>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (Platform.isAndroid && !await _requestAudioAccess()) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Yomi needs access to your music to read a folder.'),
          ),
        );
        return;
      }
      final folder = await FilePicker.getDirectoryPath();
      if (folder == null) return;
      final added = await queue.addFolder(folder);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            added == 0 ? 'No new music in that folder' : 'Added $added files',
          ),
        ),
      );
    } on FileSystemException catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not read that folder: ${error.message}')),
      );
    }
  }

  /// Android 13 replaced the storage permission with one just for audio.
  Future<bool> _requestAudioAccess() async {
    if ((await Permission.audio.request()).isGranted) return true;
    return (await Permission.storage.request()).isGranted;
  }

  Future<void> _pickFiles(BuildContext context) async {
    final queue = context.read<UploadQueue>();
    final picked = await FilePicker.pickFiles(type: FileType.audio);
    await queue.addFiles([
      for (final file in picked)
        if (file.path != null) file.path!,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: YomiSpace.s,
      runSpacing: YomiSpace.s,
      children: [
        FilledButton.icon(
          onPressed: () => _pickFolder(context),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('Choose a folder'),
        ),
        OutlinedButton.icon(
          onPressed: () => _pickFiles(context),
          icon: const Icon(Icons.library_music_outlined, size: 18),
          label: const Text('Choose songs'),
        ),
      ],
    );
  }
}

class _PauseNotice extends StatelessWidget {
  const _PauseNotice({required this.pause});

  final UploadPause pause;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YomiSpace.m),
      decoration: BoxDecoration(
        color: YomiColors.surfaceHigh,
        borderRadius: BorderRadius.circular(YomiRadius.card),
      ),
      child: Row(
        children: [
          const Icon(Icons.pause_circle_outline_rounded),
          const SizedBox(width: YomiSpace.m),
          Expanded(
            child: Text(
              _pauseMessage(pause),
              style: yomiText(13.5, weight: FontWeight.w600, height: 1.3),
            ),
          ),
          if (pause == UploadPause.storageFull ||
              pause == UploadPause.serverNeedsUpdate)
            TextButton(
              onPressed: context.read<UploadQueue>().resume,
              child: const Text('Try again'),
            ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.queue});

  final UploadQueue queue;

  @override
  Widget build(BuildContext context) {
    final done = queue.count(UploadState.done);
    final duplicates = queue.count(UploadState.duplicate);
    final failed = queue.count(UploadState.failed);
    final handled =
        done +
        duplicates +
        failed +
        queue.count(UploadState.likelyDuplicate) +
        queue.count(UploadState.skipped);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            '$handled of ${queue.total} handled',
            if (describeTimeLeft(queue.timeLeft).isNotEmpty)
              describeTimeLeft(queue.timeLeft),
          ].join(' · '),
          style: yomiText(16, weight: FontWeight.w800),
        ),
        const SizedBox(height: YomiSpace.s),
        LinearProgressIndicator(
          value: queue.total == 0 ? 0 : handled / queue.total,
          minHeight: 3,
          color: context.accent,
          backgroundColor: YomiColors.surfaceHigh,
        ),
        const SizedBox(height: YomiSpace.s),
        Text(
          [
            '$done uploaded',
            '$duplicates already on the server',
            if (failed > 0) '$failed failed',
          ].join(' · '),
          style: yomiText(
            13,
            weight: FontWeight.w500,
            color: YomiColors.textSecondary,
          ),
        ),
        Row(
          children: [
            if (failed > 0)
              TextButton(
                onPressed: queue.retryFailed,
                child: const Text('Retry failed'),
              ),
            if (queue.remaining < queue.total)
              TextButton(
                onPressed: queue.clearFinished,
                child: const Text('Clear finished'),
              ),
          ],
        ),
      ],
    );
  }
}

class _LikelyHeader extends StatelessWidget {
  const _LikelyHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Might already be on the server ($count)',
                style: yomiText(16, weight: FontWeight.w800),
              ),
            ),
            TextButton(
              onPressed: context.read<UploadQueue>().uploadAllLikelyAnyway,
              child: const Text('Upload all'),
            ),
          ],
        ),
        Text(
          'Same artist, title and length as a song you have. A remaster or live '
          'version can match by mistake, so these wait for you.',
          style: yomiText(
            13,
            weight: FontWeight.w500,
            height: 1.35,
            color: YomiColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _LikelyRow extends StatelessWidget {
  const _LikelyRow({required this.item});

  final UploadItem item;

  @override
  Widget build(BuildContext context) {
    final queue = context.read<UploadQueue>();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: kPagePadding),
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: yomiText(14, weight: FontWeight.w600),
      ),
      subtitle: item.facts?.artist == null
          ? null
          : Text(
              item.facts!.artist!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(
                12.5,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => queue.skipLikely(item.path),
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () => queue.uploadAnyway(item.path),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.item});

  final UploadItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (item.state) {
      UploadState.queued => (
        Icons.schedule_rounded,
        YomiColors.textSecondary,
        'Checking',
      ),
      UploadState.ready => (
        Icons.schedule_rounded,
        YomiColors.textSecondary,
        'Waiting',
      ),
      UploadState.uploading => (
        Icons.cloud_upload_rounded,
        context.accent,
        'Uploading',
      ),
      UploadState.done => (
        Icons.check_circle_rounded,
        YomiColors.success,
        'Uploaded',
      ),
      UploadState.duplicate => (
        Icons.check_circle_outline_rounded,
        YomiColors.textSecondary,
        'Already on the server',
      ),
      UploadState.likelyDuplicate => (
        Icons.help_outline_rounded,
        YomiColors.textSecondary,
        'Needs a decision',
      ),
      UploadState.skipped => (
        Icons.remove_circle_outline_rounded,
        YomiColors.textSecondary,
        'Skipped',
      ),
      UploadState.failed => (
        Icons.error_rounded,
        YomiColors.danger,
        item.error ?? 'Failed',
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kPagePadding,
        vertical: YomiSpace.s,
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: YomiSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(14, weight: FontWeight.w600),
                ),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(
                    12,
                    weight: FontWeight.w500,
                    color: item.state == UploadState.failed
                        ? YomiColors.danger
                        : YomiColors.textSecondary,
                  ),
                ),
                if (item.state == UploadState.uploading)
                  Padding(
                    padding: const EdgeInsets.only(top: YomiSpace.xs),
                    child: LinearProgressIndicator(
                      value: context.read<UploadQueue>().progressOf(item.path),
                      minHeight: 2,
                      color: context.accent,
                      backgroundColor: YomiColors.surfaceHigh,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
