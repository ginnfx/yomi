import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../dev_hooks.dart';

import 'package:provider/provider.dart';

import '../../state/connectivity_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/nav_bar.dart';
import '../widgets/offline_banner.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'offline_page.dart';
import 'now_playing_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'upload_page.dart';

const double _bottomClearance =
    kMiniPlayerHeight + kMiniPlayerGap + kNavBarHeight + 24;

/// Tabs with the floating player and navigation over them. Content scrolls underneath the glass.
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
    final bottomSafe = media.padding.bottom;
    final isDisconnected =
        context.select<SessionController, bool>((s) => !s.isServerReachable) ||
        context.select<ConnectivityController, bool>((c) => c.isOffline);
    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: Stack(
          children: [
            Positioned.fill(
              child: MediaQuery(
                data: media.copyWith(
                  padding: media.padding.copyWith(
                    bottom: _bottomClearance + bottomSafe,
                  ),
                ),
                child: Column(
                  children: [
                    SafeArea(bottom: false, child: const StatusBanner()),
                    // The banner's SafeArea already reserved the top inset; pages must not add it again.
                    Expanded(
                      child: MediaQuery.removePadding(
                        context: context,
                        removeTop: true,
                        child: FadeTransition(
                          opacity: CurvedAnimation(
                            parent: _fade,
                            curve: Curves.easeOut,
                          ),
                          child: IndexedStack(
                            index: isDisconnected ? _pages.length : _index,
                            children: [..._pages, const OfflinePage()],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const MiniPlayer(),
                    if (!isDisconnected)
                      YomiNavBar(
                        items: _items,
                        index: _index,
                        onSelected: _select,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
