import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/player_controller.dart';
import '../theme.dart';
import 'mini_player.dart';

/// Pins the mini player under a pushed page, so it shows on every screen except the
/// full player. Tab pages get theirs from the shell.
class RouteMiniPlayer extends StatelessWidget {
  const RouteMiniPlayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final player = Provider.of<PlayerController?>(context);
    if (player == null) return child;
    final hasSong = player.current != null;
    return ColoredBox(
      color: context.pageColor,
      child: Column(
        children: [
          Expanded(
            // The bar below takes the bottom inset, so the page must not pad for it too.
            child: MediaQuery.removePadding(
              context: context,
              removeBottom: hasSong,
              child: child,
            ),
          ),
          if (hasSong)
            const SafeArea(top: false, child: MiniPlayer())
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}
