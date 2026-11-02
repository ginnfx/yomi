import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/lyrics.dart';
import '../../core/models.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';

/// Lyrics that follow the song. Synced lyrics highlight the current line and tapping a line jumps to it.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.song});

  final Song song;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  static const double _lineExtent = 54;
  final _scroll = ScrollController();
  late Future<Lyrics?> _lyrics = _load();
  int _lastActive = -2;

  Future<Lyrics?> _load() => context.read<LyricsService>().forSong(
    context.read<SessionController>().client,
    widget.song,
  );

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (old.song.id != widget.song.id) {
      _lastActive = -2;
      _lyrics = _load();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow(int active, double viewport) {
    if (active == _lastActive || !_scroll.hasClients) return;
    _lastActive = active;
    final target = (active * _lineExtent - viewport / 2 + _lineExtent / 2)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lyrics?>(
      future: _lyrics,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done)
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        final lyrics = snapshot.data;
        if (lyrics == null)
          return Center(
            child: Text(
              'No lyrics for this one',
              style: yomiText(
                15,
                weight: FontWeight.w600,
                color: Colors.white60,
              ),
            ),
          );
        return LayoutBuilder(
          builder: (context, box) =>
              lyrics.isSynced ? _synced(lyrics, box.maxHeight) : _plain(lyrics),
        );
      },
    );
  }

  Widget _plain(Lyrics lyrics) => ListView(
    controller: _scroll,
    padding: const EdgeInsets.symmetric(vertical: 20),
    children: [
      for (final l in lyrics.lines)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Text(
            l.text,
            style: yomiText(
              20,
              weight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.85),
              height: 1.3,
            ),
          ),
        ),
    ],
  );

  Widget _synced(Lyrics lyrics, double height) {
    final player = context.read<PlayerController>();
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snapshot) {
        final active = lyrics.activeIndex(snapshot.data ?? Duration.zero);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _follow(active, height),
        );
        return ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.symmetric(vertical: height / 2 - _lineExtent / 2),
          itemExtent: _lineExtent,
          itemCount: lyrics.lines.length,
          itemBuilder: (context, i) {
            final line = lyrics.lines[i];
            final distance = (i - active).abs();
            final alpha = i == active ? 1.0 : (distance == 1 ? 0.5 : 0.3);
            return InkWell(
              onTap: () => player.seek(line.start!),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 250),
                  style: yomiText(
                    i == active ? 24 : 21,
                    weight: FontWeight.w800,
                    color: Colors.white.withValues(alpha: alpha),
                    height: 1.15,
                  ),
                  child: Text(
                    line.text.isEmpty ? '♪' : line.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
