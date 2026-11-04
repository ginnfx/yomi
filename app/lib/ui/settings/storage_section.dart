import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/offline/audio_cache.dart';
import '../../state/download_manager.dart';
import '../../state/offline_keeper.dart';
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
    final used = downloads.downloadedBytes + _cacheBytes;
    return Column(
      children: [
        SettingsGroup(
          title: 'Storage',
          footer:
              'Yomi saves your playlists, songs on repeat and songs you play '
              'within this limit, keeping what you played most recently. Songs '
              "you download yourself don't count and are never removed.",
          children: [
            SettingsInfoRow(
              icon: Icons.sd_storage_rounded,
              title: '${formatBytes(used)} used',
              detail: 'Limit ${settings.storageLimitGb} GB',
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ChoicePills<int>(
                values: storageLimitChoicesGb,
                selected: settings.storageLimitGb,
                label: (gb) => '$gb GB',
                onSelected: (gb) async {
                  await settings.setStorageLimitGb(gb);
                  await context.read<OfflineKeeper>().run();
                  await cache.evict();
                  await _refreshCacheSize();
                },
              ),
            ),
            SettingsSwitch(
              title: 'Keep my playlists offline',
              value: settings.keepPlaylistsOffline,
              onChanged: settings.setKeepPlaylistsOffline,
            ),
            SettingsSwitch(
              title: 'Download on Wi-Fi only',
              value: settings.wifiOnlyDownloads,
              onChanged: settings.setWifiOnlyDownloads,
            ),
            SettingsInfoRow(
              icon: Icons.delete_outline_rounded,
              title: '${downloads.downloadedSongs.length} saved songs',
              detail: formatBytes(downloads.downloadedBytes),
              action: TextButton(
                onPressed: used == 0
                    ? null
                    : () => _confirm(
                        'Remove everything saved?',
                        'Songs will play from the server again. Your library is '
                            'not affected.',
                        () async {
                          await downloads.removeAll();
                          await cache.clear();
                        },
                      ),
                child: const Text('Remove all'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
