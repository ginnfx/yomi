import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../state/playback_sync_controller.dart';
import '../theme.dart';

class ContinueListening extends StatelessWidget {
  const ContinueListening({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<PlaybackSyncController>();
    final remote = sync.remote;
    if (!sync.enabled || remote == null) return const SizedBox.shrink();
    if (context.isWideLayout) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(kPagePadding, 18, kPagePadding, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: context.accent.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.accent.withValues(alpha: 0.16)),
          ),
          child: Row(
            children: [
              Icon(Icons.devices_rounded, size: 24, color: context.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'From ${remote.deviceLabel}',
                      style: yomiText(
                        11,
                        color: context.accent,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${remote.current.title} · ${formatDuration(remote.position)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: yomiText(13, weight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: sync.isTakingOver ? null : sync.continueHere,
                icon: const Icon(Icons.play_arrow_rounded, size: 19),
                label: Text(
                  sync.isTakingOver ? 'Connecting…' : 'Continue here',
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 20, kPagePadding, 0),
      child: Card(
        color: context.accent.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Continue from ${remote.deviceLabel}',
                style: yomiText(17, weight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                '${remote.current.title} · ${remote.current.artist}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                'At ${formatDuration(remote.position)}',
                style: yomiText(12, color: YomiColors.textSecondary),
              ),
              if (sync.error != null)
                Text(
                  sync.error!,
                  style: yomiText(12, color: YomiColors.textSecondary),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: sync.isTakingOver ? null : sync.continueHere,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Continue here'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
