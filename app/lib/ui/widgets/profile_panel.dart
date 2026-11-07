import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/profile_controller.dart';
import '../../state/session.dart';
import '../pages/dashboard_page.dart';
import '../pages/settings_page.dart';
import '../settings/profile_section.dart';
import '../stats/stats_page.dart';
import '../pages/friend_profile_page.dart';
import '../theme.dart';
import 'profile_header.dart';

const double _panelWidth = 320;

/// Slides the profile panel in from the left, like Spotify's side menu.
void openProfilePanel(BuildContext context) {
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close profile',
    barrierColor: Colors.black54,
    transitionDuration: YomiMotion.standard,
    pageBuilder: (_, _, _) =>
        const Align(alignment: Alignment.centerLeft, child: _ProfilePanel()),
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(-1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: YomiMotion.curve)),
      child: child,
    ),
  );
}

class _ProfilePanel extends StatelessWidget {
  const _ProfilePanel();

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileController>();
    final session = context.read<SessionController>();
    final banner = profile.bannerFile;
    final topInset = MediaQuery.paddingOf(context).top;
    return SizedBox(
      width: _panelWidth,
      height: double.infinity,
      child: Material(
        color: YomiColors.surface,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            ProfileHeader(
              topInset: topInset,
              banner: banner == null ? null : FileImage(banner),
              avatar: const ProfileAvatar(size: kProfileAvatarSize),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                YomiSpace.l,
                kProfileAvatarSize / 2 + YomiSpace.m,
                YomiSpace.l,
                YomiSpace.l,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName(session.username),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: yomiText(22, weight: FontWeight.w800),
                  ),
                  Text(
                    session.username,
                    style: yomiText(
                      13,
                      weight: FontWeight.w500,
                      color: YomiColors.textSecondary,
                    ),
                  ),
                  if (profile.bio.isNotEmpty) ...[
                    const SizedBox(height: YomiSpace.m),
                    Text(
                      profile.bio,
                      style: yomiText(
                        14,
                        weight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: YomiColors.hairline),
            ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: Text(
                'View my profile',
                style: yomiText(15, weight: FontWeight.w600),
              ),
              onTap: () {
                final navigator = Navigator.of(context);
                final me = context.read<SessionController>().username;
                navigator.pop();
                openProfile(navigator.context, me);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(
                'Edit profile',
                style: yomiText(15, weight: FontWeight.w600),
              ),
              onTap: () => _openSettings(context),
            ),
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: Text(
                'Server status',
                style: yomiText(15, weight: FontWeight.w600),
              ),
              onTap: () {
                final navigator = Navigator.of(context);
                navigator.pop();
                openDashboard(navigator.context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.insights_rounded),
              title: Text(
                'Stats and Wrapped',
                style: yomiText(15, weight: FontWeight.w600),
              ),
              onTap: () {
                final navigator = Navigator.of(context);
                navigator.pop();
                navigator.push(
                  yomiRoute<void>(builder: (_) => const StatsPage()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text(
                'Settings',
                style: yomiText(15, weight: FontWeight.w600),
              ),
              onTap: () => _openSettings(context),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    final navigator = Navigator.of(context);
    navigator.pop();
    openSettings(navigator.context);
  }
}
