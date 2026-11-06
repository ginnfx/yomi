import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'error_view.dart';
import 'shimmer.dart';

/// Shows data as soon as there is any, and refreshes it quietly.
///
/// A skeleton appears only when there is nothing to show yet, and an error only when
/// loading failed with nothing to show. [initialData] appears on the first frame.
/// Changing [reloadKey], or an update in [refreshOn], reloads in place.
class AsyncSection<T> extends StatefulWidget {
  const AsyncSection({
    super.key,
    required this.load,
    required this.builder,
    this.skeleton = const SongListSkeleton(),
    this.initialData,
    this.reloadKey,
    this.refreshOn,
    this.refreshEndpoints = const {},
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;
  final Widget skeleton;
  final T? initialData;
  final Object? reloadKey;

  /// Announces which endpoints changed; reloads when one is in [refreshEndpoints].
  final Stream<String>? refreshOn;
  final Set<String> refreshEndpoints;

  @override
  State<AsyncSection<T>> createState() => _AsyncSectionState<T>();
}

class _AsyncSectionState<T> extends State<AsyncSection<T>> {
  T? _data;
  bool _hasData = false;
  Object? _error;
  int _generation = 0;
  StreamSubscription<String>? _updates;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialData;
    if (initial != null) {
      _data = initial;
      _hasData = true;
    }
    _updates = widget.refreshOn?.listen((endpoint) {
      if (widget.refreshEndpoints.contains(endpoint)) unawaited(_load());
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(AsyncSection<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadKey != widget.reloadKey) unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_updates?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final data = await Future<T>.sync(widget.load)
          .timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _hasData = true;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      debugPrint('Could not refresh a section: $error');
      if (!_hasData) setState(() => _error = error);
    }
  }

  void _retry() {
    setState(() => _error = null);
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final Widget child;
    if (_hasData) {
      child = KeyedSubtree(
        key: const ValueKey('data'),
        child: widget.builder(context, _data as T),
      );
    } else if (error != null) {
      child = KeyedSubtree(
        key: const ValueKey('error'),
        child: ErrorView(error: error, onRetry: _retry),
      );
    } else {
      child = KeyedSubtree(
        key: const ValueKey('skeleton'),
        child: widget.skeleton,
      );
    }
    return AnimatedSwitcher(
      duration: context.motion(YomiMotion.standard),
      switchInCurve: YomiMotion.curve,
      layoutBuilder: _topAligned,
      child: child,
    );
  }
}

/// Keeps the outgoing state above the incoming one, aligned to the top, so lists
/// don't jump to the middle while they swap.
Widget _topAligned(Widget? current, List<Widget> previous) =>
    Stack(alignment: Alignment.topCenter, children: [...previous, ?current]);
