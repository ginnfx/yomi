import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../dev_hooks.dart';

import 'package:provider/provider.dart';

import '../../state/connectivity_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/desktop_player.dart';
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
    if (defaultTargetPlatform == TargetPlatform.macOS &&
        media.size.width >= 900) {
      return _desktop(context, media, isDisconnected);
    }
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

  Widget _desktop(
    BuildContext context,
    MediaQueryData media,
    bool isDisconnected,
  ) {
    return AuroraBackground(
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
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 30),
                              child: Text(
                                'Yomi',
                                style: yomiText(
                                  30,
                                  weight: FontWeight.w800,
                                  color: context.accent,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 12,
                                bottom: 12,
                              ),
                              child: Text(
                                'YOUR MUSIC',
                                style: yomiText(
                                  10,
                                  weight: FontWeight.w700,
                                  color: YomiColors.textSecondary,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ),
                            for (var i = 0; i < _items.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: ListTile(
                                  dense: true,
                                  selected: !isDisconnected && _index == i,
                                  selectedColor: context.accent,
                                  selectedTileColor: context.accent.withValues(
                                    alpha: 0.10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(9),
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
                  const VerticalDivider(width: 1, color: Colors.white10),
                  Expanded(
                    child: Column(
                      children: [
                        const SafeArea(bottom: false, child: StatusBanner()),
                        Expanded(
                          child: MediaQuery(
                            data: media.copyWith(padding: EdgeInsets.zero),
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
