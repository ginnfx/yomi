import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../pages/now_playing_page.dart';
import '../pages/settings_page.dart';

/// Application shortcuts remain available on pushed pages, including lyrics.
/// Space is handled by Focus so typing in a text field keeps its usual behavior.
class DesktopControls extends StatelessWidget {
  const DesktopControls({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final signedIn = context.watch<SessionController>().isSignedIn;
    void withPage(void Function(BuildContext) action) {
      final pageContext = navigatorKey.currentState?.overlay?.context;
      if (signedIn && pageContext != null) action(pageContext);
    }

    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'Yomi',
          menus: [
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.about,
            ),
            PlatformMenuItem(
              label: 'Settings…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                meta: true,
              ),
              onSelected: signedIn ? () => withPage(openSettings) : null,
            ),
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hide,
            ),
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.quit,
            ),
          ],
        ),
        const PlatformMenu(
          label: 'Edit',
          menus: [
            PlatformMenuItem(
              label: 'Undo',
              shortcut: SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
              onSelectedIntent: UndoTextIntent(SelectionChangedCause.keyboard),
            ),
            PlatformMenuItem(
              label: 'Redo',
              shortcut: SingleActivator(
                LogicalKeyboardKey.keyZ,
                meta: true,
                shift: true,
              ),
              onSelectedIntent: RedoTextIntent(SelectionChangedCause.keyboard),
            ),
            PlatformMenuItem(
              label: 'Cut',
              shortcut: SingleActivator(LogicalKeyboardKey.keyX, meta: true),
              onSelectedIntent: CopySelectionTextIntent.cut(
                SelectionChangedCause.keyboard,
              ),
            ),
            PlatformMenuItem(
              label: 'Copy',
              shortcut: SingleActivator(LogicalKeyboardKey.keyC, meta: true),
              onSelectedIntent: CopySelectionTextIntent.copy,
            ),
            PlatformMenuItem(
              label: 'Paste',
              shortcut: SingleActivator(LogicalKeyboardKey.keyV, meta: true),
              onSelectedIntent: PasteTextIntent(SelectionChangedCause.keyboard),
            ),
            PlatformMenuItem(
              label: 'Select All',
              shortcut: SingleActivator(LogicalKeyboardKey.keyA, meta: true),
              onSelectedIntent: SelectAllTextIntent(
                SelectionChangedCause.keyboard,
              ),
            ),
          ],
        ),
        PlatformMenu(
          label: 'Playback',
          menus: [
            PlatformMenuItem(
              label: player.isPlaying ? 'Pause' : 'Play',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyP,
                meta: true,
              ),
              onSelected: player.current == null
                  ? null
                  : () => unawaited(player.togglePlay()),
            ),
            PlatformMenuItem(
              label: 'Next song',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.arrowRight,
                meta: true,
              ),
              onSelected: player.current == null
                  ? null
                  : () => unawaited(player.next()),
            ),
            PlatformMenuItem(
              label: 'Previous song',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.arrowLeft,
                meta: true,
              ),
              onSelected: player.current == null
                  ? null
                  : () => unawaited(player.previous()),
            ),
            PlatformMenuItem(
              label: 'Shuffle',
              onSelected: player.current == null
                  ? null
                  : () => unawaited(player.toggleShuffle()),
            ),
            PlatformMenuItem(
              label: 'Repeat',
              onSelected: player.current == null
                  ? null
                  : () => unawaited(player.cycleRepeat()),
            ),
            PlatformMenuItem(
              label: 'Now Playing',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                meta: true,
              ),
              onSelected: player.current == null
                  ? null
                  : () => withPage(openNowPlaying),
            ),
          ],
        ),
        const PlatformMenu(
          label: 'Window',
          menus: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
          ],
        ),
      ],
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent ||
              event.logicalKey != LogicalKeyboardKey.space ||
              player.current == null) {
            return KeyEventResult.ignored;
          }
          final focus = FocusManager.instance.primaryFocus;
          if (focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
              null) {
            return KeyEventResult.ignored;
          }
          unawaited(player.togglePlay());
          return KeyEventResult.handled;
        },
        child: child,
      ),
    );
  }
}
