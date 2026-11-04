import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/lyrics.dart';
import '../../state/player_controller.dart';
import '../theme.dart';

const double _lineGap = 18;

/// After scrolling by hand, how long the view waits before following the song again.
const Duration _followResumeAfter = Duration(seconds: 4);

/// Where the active line sits in the viewport, from the top.
const double _activeLineAnchor = 0.3;

/// The top of each line when laid out at [width]. Lines wrap, so they have to be
/// measured to know where to scroll.
List<double> measureLyricTops({
  required List<String> lines,
  required double width,
  required TextStyle style,
  required TextScaler textScaler,
  required TextDirection textDirection,
  double gap = _lineGap,
}) {
  final tops = <double>[];
  var top = 0.0;
  for (final line in lines) {
    tops.add(top);
    final painter = TextPainter(
      text: TextSpan(text: line, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: width);
    top += painter.height + gap;
    painter.dispose();
  }
  return List.unmodifiable(tops);
}

/// Lyrics that follow the song. Synced lyrics highlight the current line and
/// tapping a line jumps to it.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.lyrics, this.fontSize = 26});

  final Lyrics lyrics;
  final double fontSize;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  double? _measuredWidth;
  TextScaler? _measuredScaler;
  Lyrics? _measuredLyrics;
  List<double> _measuredTops = const [];

  final _scroll = ScrollController();
  int _lastActive = -2;
  DateTime _followPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _textOf(LyricLine line) => line.text.isEmpty ? '♪' : line.text;

  TextStyle get _style => yomiText(
    widget.fontSize,
    weight: FontWeight.w800,
    height: 1.2,
    letterSpacing: -0.3,
  );

  void _follow(int active, List<double> tops, double viewport) {
    if (active == _lastActive || !_scroll.hasClients) return;
    if (DateTime.now().isBefore(_followPausedUntil)) return;
    _lastActive = active;
    final lineTop = active < 0 ? 0.0 : tops[active];
    final target = (lineTop - viewport * _activeLineAnchor).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: YomiMotion.standard,
      curve: YomiMotion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.black,
          Colors.black,
          Colors.transparent,
        ],
        stops: [0, 0.06, 0.92, 1],
      ).createShader(bounds),
      child: LayoutBuilder(
        builder: (context, box) =>
            widget.lyrics.isSynced ? _synced(context, box) : _plain(box),
      ),
    );
  }

  EdgeInsets _padding(BoxConstraints box) =>
      EdgeInsets.only(top: YomiSpace.xl, bottom: box.maxHeight * 0.6);

  Widget _plain(BoxConstraints box) => ListView.builder(
    controller: _scroll,
    padding: _padding(box),
    itemCount: widget.lyrics.lines.length,
    itemBuilder: (_, i) => Padding(
      padding: const EdgeInsets.only(bottom: _lineGap),
      child: Text(_textOf(widget.lyrics.lines[i]), style: _style),
    ),
  );

  Widget _synced(BuildContext context, BoxConstraints box) {
    final player = context.read<PlayerController>();
    final lines = widget.lyrics.lines;
    final scaler = MediaQuery.textScalerOf(context);
    // Laying out every line is slow, so it's only redone when the result would differ.
    if (_measuredWidth != box.maxWidth ||
        _measuredScaler != scaler ||
        !identical(_measuredLyrics, widget.lyrics)) {
      _measuredWidth = box.maxWidth;
      _measuredScaler = scaler;
      _measuredLyrics = widget.lyrics;
      _measuredTops = measureLyricTops(
        lines: [for (final line in lines) _textOf(line)],
        width: box.maxWidth,
        style: _style,
        textScaler: scaler,
        textDirection: Directionality.of(context),
      );
    }
    final tops = _measuredTops;
    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _followPausedUntil = DateTime.now().add(_followResumeAfter);
        _lastActive = -2;
        return false;
      },
      child: StreamBuilder<Duration>(
        stream: player.positionStream,
        builder: (context, snapshot) {
          final active = widget.lyrics.activeIndex(
            snapshot.data ?? Duration.zero,
          );
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _follow(active, tops, box.maxHeight),
          );
          return ListView.builder(
            controller: _scroll,
            padding: _padding(box),
            itemCount: lines.length,
            itemBuilder: (context, i) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _followPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
                player.seek(lines[i].start!);
              },
              child: Padding(
                padding: const EdgeInsets.only(bottom: _lineGap),
                child: AnimatedDefaultTextStyle(
                  duration: YomiMotion.standard,
                  style: _style.copyWith(
                    color: Colors.white.withValues(
                      alpha: i == active ? 1 : 0.38,
                    ),
                  ),
                  child: Text(_textOf(lines[i])),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
