import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../settings/appearance_section.dart';
import '../settings/connection_section.dart';
import '../settings/home_layout_section.dart';
import '../settings/listening_sync_section.dart';
import '../settings/profile_section.dart';
import '../settings/settings_widgets.dart';
import '../settings/storage_section.dart';
import '../theme.dart';

void openSettings(BuildContext context) {
  Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
}

/// Every option in one place. Each group is its own small widget in lib/ui/settings.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text('Settings', style: yomiText(20, weight: FontWeight.w800)),
        ),
        body: ListView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + 32,
          ),
          children: [
            const ProfileSection(),
            const ListeningSyncSection(),
            const ConnectionSection(),
            const AppearanceSection(),
            const HomeLayoutSection(),
            const StorageSection(),
            SettingsGroup(
              title: 'Account',
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.logout_rounded),
                  title: Text(
                    'Sign out',
                    style: yomiText(15, weight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    'Removes your login from this device. Downloads stay.',
                    style: yomiText(
                      12.5,
                      weight: FontWeight.w500,
                      color: YomiColors.textSecondary,
                    ),
                  ),
                  onTap: () async {
                    final player = context.read<PlayerController>();
                    final session = context.read<SessionController>();
                    final navigator = Navigator.of(context);
                    player.attach(null);
                    await session.signOut();
                    navigator.popUntil((route) => route.isFirst);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
