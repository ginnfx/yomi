import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../state/youtube_controller.dart';
import '../theme.dart';

/// Where to look for a song that isn't in the library.
Uri youtubeSearchFor(String artist, String title) => Uri.https(
  'www.youtube.com',
  '/results',
  {'search_query': '$artist $title'},
);

Future<void> _openSearch(String artist, String title) => launchUrl(
  youtubeSearchFor(artist, title),
  mode: LaunchMode.externalApplication,
);

/// Plays a song the library doesn't have straight from YouTube, showing progress.
/// Where this device can't run yt-dlp it opens a YouTube search instead.
class YoutubePlayButton extends StatelessWidget {
  const YoutubePlayButton({
    super.key,
    required this.artist,
    required this.title,
    this.durationSeconds,
    this.wantExplicit = false,
  });

  final String artist;
  final String title;
  final int? durationSeconds;
  final bool wantExplicit;

  @override
  Widget build(BuildContext context) {
    final youtube = context.watch<YoutubeController?>();
    if (youtube == null || !youtube.isAvailable) {
      return IconButton(
        tooltip: 'Find on YouTube',
        icon: const Icon(Icons.open_in_new_rounded),
        onPressed: () => _openSearch(artist, title),
      );
    }
    final state = youtube.stateFor(artist, title, wantExplicit: wantExplicit);
    return AnimatedSwitcher(
      duration: context.motion(YomiMotion.quick),
      child: switch (state?.step) {
        YoutubeStep.searching || YoutubeStep.downloading => SizedBox(
          key: const ValueKey('busy'),
          width: 48,
          height: 48,
          child: Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: state?.step == YoutubeStep.downloading
                    ? state?.progress
                    : null,
                color: context.accent,
              ),
            ),
          ),
        ),
        YoutubeStep.failed => IconButton(
          key: const ValueKey('failed'),
          tooltip: 'Try YouTube again',
          icon: const Icon(Icons.error_outline_rounded),
          color: YomiColors.danger,
          onPressed: () => _play(context, youtube),
        ),
        _ => IconButton(
          key: const ValueKey('play'),
          tooltip: 'Play from YouTube',
          icon: const Icon(Icons.play_circle_outline_rounded),
          color: context.accent,
          onPressed: () => _play(context, youtube),
        ),
      },
    );
  }

  Future<void> _play(BuildContext context, YoutubeController youtube) async {
    final messenger = ScaffoldMessenger.of(context);
    final isPlaying = await youtube.play(
      artist: artist,
      title: title,
      durationSeconds: durationSeconds,
      wantExplicit: wantExplicit,
    );
    if (isPlaying) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          youtube.stateFor(artist, title, wantExplicit: wantExplicit)?.error ??
              "Couldn't play it.",
        ),
        action: SnackBarAction(
          label: 'Open YouTube',
          onPressed: () => _openSearch(artist, title),
        ),
      ),
    );
  }
}

/// Shown while a YouTube song plays: says where it's from, and saves it to the library.
class YoutubeSaveChip extends StatelessWidget {
  const YoutubeSaveChip({super.key, required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final youtube = context.watch<YoutubeController?>();
    if (youtube == null || !song.isFromYoutube) return const SizedBox.shrink();
    final isSaved = youtube.isSaved(song);
    return ActionChip(
      avatar: Icon(
        isSaved ? Icons.check_rounded : Icons.library_add_rounded,
        size: 18,
      ),
      label: Text(
        isSaved ? 'Saving to your library' : 'From YouTube · Save to library',
      ),
      onPressed: isSaved
          ? null
          : () async {
              final messenger = ScaffoldMessenger.of(context);
              final isDone = await youtube.save(song);
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    isDone
                        ? 'Uploading "${song.title}" to your library'
                        : "Couldn't save it. Try playing it again first.",
                  ),
                ),
              );
            },
    );
  }
}
