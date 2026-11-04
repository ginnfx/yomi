import 'dart:async';

import 'package:flutter/material.dart';

import 'error_view.dart';
import 'shimmer.dart';

/// Loads data once, shows a shimmering skeleton while waiting, and offers retry on failure.
class AsyncSection<T> extends StatefulWidget {
  const AsyncSection({
    super.key,
    required this.load,
    required this.builder,
    this.skeleton = const SongListSkeleton(),
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;
  final Widget skeleton;

  @override
  State<AsyncSection<T>> createState() => _AsyncSectionState<T>();
}

class _AsyncSectionState<T> extends State<AsyncSection<T>> {
  late Future<T> _future = _load();

  Future<T> _load() =>
      Future<T>.sync(widget.load).timeout(const Duration(seconds: 20));

  void _retry() => setState(() {
    _future = _load();
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done)
          return widget.skeleton;
        if (snapshot.hasError)
          return ErrorView(error: snapshot.error!, onRetry: _retry);
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: widget.builder(context, snapshot.data as T),
        );
      },
    );
  }
}
