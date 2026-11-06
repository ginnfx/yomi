import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/assistant_controller.dart';
import '../theme.dart';
import 'report_sheet.dart';
import 'youtube_play_button.dart';

/// How many suggestions Home shows.
const int _shown = 6;

/// "You might like": songs the library doesn't have yet, from DeepSeek, refreshed weekly.
class DiscoverSection extends StatefulWidget {
  const DiscoverSection({super.key});

  @override
  State<DiscoverSection> createState() => _DiscoverSectionState();
}

class _DiscoverSectionState extends State<DiscoverSection> {
  @override
  void initState() {
    super.initState();
    // After the first frame: refreshing notifies listeners, which can't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final discover = context.read<DiscoverController?>();
      if (discover != null) unawaited(discover.refreshIfDue());
    });
  }

  @override
  Widget build(BuildContext context) {
    // Screens built without it (in tests, or before sign-in) show nothing.
    final songs = context.watch<DiscoverController?>()?.songs ?? const [];
    return AnimatedSize(
      duration: context.motion(YomiMotion.standard),
      alignment: Alignment.topCenter,
      child: songs.isEmpty
          ? const SizedBox(width: double.infinity)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kPagePadding,
                    YomiSpace.xl,
                    kPagePadding,
                    YomiSpace.xs,
                  ),
                  child: Text(
                    'You might like',
                    style: yomiText(22, weight: FontWeight.w800),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
                  child: Text(
                    "New to your library. Play them from YouTube or ask for them to be added.",
                    style: yomiText(13, color: YomiColors.textSecondary),
                  ),
                ),
                for (final song in songs.take(_shown))
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: kPagePadding,
                    ),
                    title: Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: yomiText(15, weight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      song.reason.isEmpty
                          ? song.artist
                          : '${song.artist} · ${song.reason}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        YoutubePlayButton(
                          artist: song.artist,
                          title: song.title,
                        ),
                        IconButton(
                          tooltip: 'Request it',
                          icon: const Icon(Icons.add_task_rounded),
                          onPressed: () => requestSong(
                            context,
                            artist: song.artist,
                            title: song.title,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
