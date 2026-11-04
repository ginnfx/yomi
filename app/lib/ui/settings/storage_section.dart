import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/offline/audio_cache.dart';
import '../../state/download_manager.dart';
import '../../state/settings.dart';
import '../theme.dart';
import 'settings_widgets.dart';

/// Playback behaviour, downloads and the song cache.
class StorageSection extends StatefulWidget {
  const StorageSection({super.key});

  @override
  State<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<StorageSection> {
  int _cacheBytes = 0;

  @override
  void initState() {
    super.initState();
    _refreshCacheSize();
  }

  Future<void> _refreshCacheSize() async {
    final size = await context.read<AudioCache>().sizeBytes();
    if (mounted) setState(() => _cacheBytes = size);
  }

  Future<void> _confirm(
    String title,
    String body,
    Future<void> Function() action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: yomiText(18, weight: FontWeight.w800)),
        content: Text(
          body,
          style: yomiText(
            14,
            weight: FontWeight.w500,
            color: YomiColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await action();
      await _refreshCacheSize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final downloads = context.watch<DownloadManager>();
    final cache = context.read<AudioCache>();
    return Column(
      children: [
        SettingsGroup(
          title: 'Playback',
          children: [
            SettingsSwitch(
              title: 'Cache songs as you listen',
              value: settings.cachePlayedSongs,
              onChanged: settings.setCachePlayedSongs,
            ),
            SettingsSwitch(
              title: 'Preload next songs',
              value: settings.preloadNext,
              onChanged: settings.setPreloadNext,
            ),
            SettingsInfoRow(
              icon: Icons.bolt_rounded,
              title: 'Song cache',
              detail:
                  '${formatBytes(_cacheBytes)} of ${formatBytes(settings.cacheLimitBytes)}',
              action: TextButton(
                onPressed: _cacheBytes == 0
                    ? null
                    : () => _confirm(
                        'Clear the cache?',
                        'Songs you replay will be fetched from the server again.',
                        cache.clear,
                      ),
                child: const Text('Clear'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ChoicePills<int>(
                values: cacheLimitChoicesMb,
                selected: settings.cacheLimitMb,
                label: (mb) => mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB',
                onSelected: (mb) async {
                  await settings.setCacheLimitMb(mb);
                  cache.maxBytes = settings.cacheLimitBytes;
                  await cache.evict();
                  await _refreshCacheSize();
                },
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Downloads',
          children: [
            SettingsInfoRow(
              icon: Icons.arrow_circle_down_rounded,
              title: '${downloads.downloadedSongs.length} downloaded songs',
              detail: formatBytes(downloads.downloadedBytes),
              action: downloads.downloadedSongs.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () => _confirm(
                        'Remove all downloads?',
                        'They stay on the server; you can download them again.',
                        downloads.removeAll,
                      ),
                      child: const Text('Remove all'),
                    ),
            ),
            SettingsSwitch(
              title: 'Download on Wi-Fi only',
              value: settings.wifiOnlyDownloads,
              onChanged: settings.setWifiOnlyDownloads,
            ),
            SettingsSwitch(
              title: 'Save songs on repeat',
              subtitle: 'Keeps songs you play 3 times in 2 weeks offline, on Wi-Fi only. Up to 2 GB, and they make room for each other.',
              value: settings.autoDownloadRepeats,
              onChanged: settings.setAutoDownloadRepeats,
            ),
          ],
        ),
      ],
    );
  }
}
