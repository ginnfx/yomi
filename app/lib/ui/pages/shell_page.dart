import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../dev_hooks.dart';

import 'package:provider/provider.dart';

import '../../state/profile_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/desktop_player.dart';
import '../widgets/nav_bar.dart';
import '../settings/profile_section.dart';
import '../widgets/offline_banner.dart';
import '../widgets/profile_panel.dart';
import '../widgets/update_banner.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'now_playing_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'upload_page.dart';

/// Banners on top, then the tab pages, padded so the player and nav bar below never cover them.
class ShellTabArea extends StatelessWidget {
  const ShellTabArea({super.key, required this.header, required this.child});

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(
          bottom: kShellBottomClearance + media.padding.bottom,
        ),
      ),
      child: Column(
        children: [
          SafeArea(bottom: false, child: header),
          // The banner's SafeArea already reserved the top inset; pages must not add it again.
          // Builder: removePadding must read the padded MediaQuery above, not the shell's.
          Expanded(
            child: Builder(
              builder: (padded) => MediaQuery.removePadding(
                context: padded,
                removeTop: true,
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tabs with the player and navigation pinned below on phones, or a sidebar on wide screens.
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage>
    with SingleTickerProviderStateMixin {
  static const _items = [
    NavItem(Icons.home_outlined, Icons.home_rounded, 'Home'),
    NavItem(Icons.search_rounded, Icons.search_rounded, 'Search'),
    NavItem(
      Icons.library_music_outlined,
      Icons.library_music_rounded,
      'Library',
    ),
    NavItem(Icons.add_circle_outline_rounded, Icons.add_circle_rounded, 'Add'),
  ];
  static const _pages = [HomePage(), SearchPage(), LibraryPage(), UploadPage()];

  late int _index = devInitialTab.clamp(0, _pages.length - 1);
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    if (devOpenSettings) {
      SchedulerBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(seconds: 6));
        if (mounted) openSettings(context);
      });
    }
    if (devOpenNowPlaying) {
      SchedulerBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(seconds: 6));
        if (mounted) openNowPlaying(context);
      });
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _fade.forward(from: 0.35);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (context.isWideLayout) return _desktop(context, media);
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: Stack(
          children: [
            Positioned.fill(
              child: ShellTabArea(
                header: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [StatusBanner(), UpdateBanner()],
                ),
                child: FadeTransition(
                  opacity: CurvedAnimation(
                    parent: _fade,
                    curve: Curves.easeOut,
                  ),
                  child: IndexedStack(index: _index, children: _pages),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      context.pageColor.withValues(alpha: 0),
                      context.pageColor,
                    ],
                    stops: const [0, 0.35],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const MiniPlayer(),
                      YomiNavBar(
                        items: _items,
                        index: _index,
                        onSelected: _select,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktop(BuildContext context, MediaQueryData media) {
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 196,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 22, 14, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const _SidebarProfile(),
                            const SizedBox(height: YomiSpace.xl),
                            for (var i = 0; i < _items.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: ListTile(
                                  dense: true,
                                  selected: _index == i,
                                  selectedColor: YomiColors.textPrimary,
                                  selectedTileColor: YomiColors.surfaceHigh,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      YomiRadius.card,
                                    ),
                                  ),
                                  leading: Icon(_items[i].icon, size: 21),
                                  title: Text(
                                    i == 3 ? 'Upload music' : _items[i].label,
                                    style: yomiText(
                                      13,
                                      weight: FontWeight.w600,
                                    ),
                                  ),
                                  onTap: () => _select(i),
                                ),
                              ),
                            const Spacer(),
                            ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.settings_outlined,
                                size: 21,
                              ),
                              title: const Text('Settings'),
                              onTap: () => openSettings(context),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1, color: YomiColors.hairline),
                  Expanded(
                    child: Column(
                      children: [
                        const SafeArea(
                          bottom: false,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [StatusBanner(), UpdateBanner()],
                          ),
                        ),
                        Expanded(
                          child: MediaQuery(
                            data: media.copyWith(padding: EdgeInsets.zero),
                            child: FadeTransition(
                              opacity: CurvedAnimation(
                                parent: _fade,
                                curve: Curves.easeOut,
                              ),
                              child: IndexedStack(
                                index: _index,
                                children: _pages,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const DesktopPlayer(),
          ],
        ),
      ),
    );
  }
}

/// The user's picture and name at the top-left of the sidebar; opens the profile panel.
class _SidebarProfile extends StatelessWidget {
  const _SidebarProfile();

  @override
  Widget build(BuildContext context) {
    final name = context.watch<ProfileController>().displayName(
      context.read<SessionController>().username,
    );
    return InkWell(
      borderRadius: BorderRadius.circular(YomiRadius.card),
      onTap: () => openProfilePanel(context),
      child: Padding(
        padding: const EdgeInsets.all(YomiSpace.s),
        child: Row(
          children: [
            const ProfileAvatar(size: 32),
            const SizedBox(width: YomiSpace.m),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: yomiText(14, weight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
