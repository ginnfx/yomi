import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/playback_sync_controller.dart';
import '../../state/settings.dart';
import 'settings_widgets.dart';

class ListeningSyncSection extends StatelessWidget {
  const ListeningSyncSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final sync = context.watch<PlaybackSyncController>();
    return SettingsGroup(
      title: 'Listening across devices',
      footer: 'Sign in with the same account on your Mac and iPhone. Both need the updated Yomi app and a connection to your server. Downloads and appearance stay on each device.',
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sync listening position'),
          subtitle: const Text(
            'Continue the same song and queue on another device.',
          ),
          value: settings.syncListening,
          onChanged: settings.setSyncListening,
        ),
        if (sync.enabled)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices_rounded),
            title: Text(
              sync.error ??
                  (sync.lastSaved == null
                      ? 'Ready to sync'
                      : 'Listening position saved'),
            ),
            subtitle: const Text(
              'Saves while listening and when you pause. The previous device pauses after a handoff.',
            ),
            trailing: IconButton(
              tooltip: 'Check listening position',
              onPressed: sync.isBusy ? null : sync.refresh,
              icon: const Icon(Icons.sync_rounded),
            ),
          ),
      ],
    );
  }
}
