import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Room the Mac's window buttons take at the top-left when content runs under
/// the title bar.
const double kMacTitleBarInset = 28;

bool get hasUnifiedMacTitleBar => Platform.isMacOS;

const MethodChannel _window = MethodChannel('yomi/window');

/// A strip of the window that moves it when dragged and zooms it on double tap,
/// like a title bar. Does nothing off the Mac.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, this.height = kMacTitleBarInset});

  final double height;

  Future<void> _call(String method) async {
    try {
      await _window.invokeMethod<void>(method);
    } on PlatformException {
      // The window simply doesn't move; nothing else depends on it.
    } on MissingPluginException {
      // Not a Mac build.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!hasUnifiedMacTitleBar) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      dragStartBehavior: DragStartBehavior.down,
      onPanStart: (_) => _call('drag'),
      onDoubleTap: () => _call('zoom'),
      child: SizedBox(height: height, width: double.infinity),
    );
  }
}
