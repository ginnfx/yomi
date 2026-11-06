import 'package:flutter/material.dart';

import '../theme.dart';

/// Where the fade starts from: low enough to notice, high enough not to flash.
const double _startOpacity = 0.35;

/// Fades [child] in again whenever [trigger] changes, while keeping the same child
/// (and so its state and scroll position), unlike an AnimatedSwitcher.
class FadeOnChange extends StatefulWidget {
  const FadeOnChange({super.key, required this.trigger, required this.child});

  final Object? trigger;
  final Widget child;

  @override
  State<FadeOnChange> createState() => _FadeOnChangeState();
}

class _FadeOnChangeState extends State<FadeOnChange>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: YomiMotion.standard,
    value: 1,
  );

  @override
  void didUpdateWidget(FadeOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger == widget.trigger) return;
    _fade.duration = context.motion(YomiMotion.standard);
    if (_fade.duration == Duration.zero) return;
    _fade.forward(from: _startOpacity);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: CurvedAnimation(parent: _fade, curve: YomiMotion.curve),
    child: widget.child,
  );
}
