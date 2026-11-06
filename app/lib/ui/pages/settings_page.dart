import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../settings/appearance_section.dart';
import '../settings/assistant_section.dart';
import '../settings/connection_section.dart';
import '../settings/invite_section.dart';
import '../settings/listening_sync_section.dart';
import '../settings/profile_section.dart';
import '../settings/settings_widgets.dart';
import '../settings/storage_section.dart';
import '../settings/version_footer.dart';
import '../stats/spotify_import_page.dart';
import '../theme.dart';

void openSettings(BuildContext context) {
  Navigator.of(context)
      .push(yomiRoute<void>(builder: (_) => const SettingsPage()));
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
            _SettingsRow(
              icon: Icons.person_rounded,
              title: 'Profile',
              page: const ProfileSection(),
            ),
            _SettingsRow(
              icon: Icons.palette_rounded,
              title: 'Appearance',
              page: const AppearanceSection(),
            ),
            _SettingsRow(
              icon: Icons.auto_awesome_rounded,
              title: 'Assistant',
              page: const AssistantSection(),
            ),
            _SettingsRow(
              icon: Icons.sd_storage_rounded,
              title: 'Storage',
              page: const StorageSection(),
            ),
            ListTile(
              leading: const Icon(Icons.library_music_rounded),
              title: Text(
                'Import from Spotify',
                style: yomiText(16, weight: FontWeight.w700),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                yomiRoute<void>(builder: (_) => const SpotifyImportPage()),
              ),
            ),
            _SettingsRow(
              icon: Icons.tune_rounded,
              title: 'Advanced',
              subtitle: 'Connection, invites and syncing between devices',
              page: const Column(
                children: [
                  ConnectionSection(),
                  InviteSection(),
                  ListeningSyncSection(),
                ],
              ),
            ),
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
            const VersionFooter(),
          ],
        ),
      ),
    );
  }
}

/// A top-level setting that opens on its own page, so the first screen stays short.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.page,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    final detail = subtitle;
    return ListTile(
      leading: Icon(icon),
      title: Text(title, style: yomiText(16, weight: FontWeight.w700)),
      subtitle: detail == null
          ? null
          : Text(
              detail,
              style: yomiText(
                12.5,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        yomiRoute<void>(
          builder: (_) => PageBackground(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                title: Text(
                  title,
                  style: yomiText(20, weight: FontWeight.w800),
                ),
              ),
              body: SingleChildScrollView(child: page),
            ),
          ),
        ),
      ),
    );
  }
}
