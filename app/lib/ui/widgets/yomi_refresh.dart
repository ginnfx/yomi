import 'package:flutter/material.dart';

import '../theme.dart';

/// Height of the band the content gives way to while refreshing.
const double kRefreshBand = 60;
const double _spinnerSettle = 10;

/// Pull to refresh that never covers the content: the spinner has a band of its
/// own, and the list slides down to make room while it works.
class YomiRefresh extends StatefulWidget {
  const YomiRefresh({super.key, required this.onRefresh, required this.child});

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<YomiRefresh> createState() => _YomiRefreshState();
}

class _YomiRefreshState extends State<YomiRefresh> {
  bool _isRefreshing = false;

  Future<void> _refresh() async {
    setState(() => _isRefreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    color: context.accent,
    backgroundColor: YomiColors.surfaceHigh,
    displacement: _spinnerSettle,
    strokeWidth: 2.5,
    elevation: 0,
    onRefresh: _refresh,
    child: AnimatedPadding(
      duration: context.motion(YomiMotion.standard),
      curve: YomiMotion.curve,
      padding: EdgeInsets.only(top: _isRefreshing ? kRefreshBand : 0),
      child: widget.child,
    ),
  );
}
