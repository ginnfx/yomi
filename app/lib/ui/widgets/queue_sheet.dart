import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/player_controller.dart';
import '../theme.dart';
import 'cover_art.dart';
import 'equalizer.dart';

/// Opens the list of what's playing and what's up next.
Future<void> showQueue(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => const QueueSheet(),
);

/// What's playing and what's up next, in the order it will really play.
class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final order = player.playOrder;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                4,
                kPagePadding,
                12,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Queue',
                  style: yomiText(22, weight: FontWeight.w800),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: order.length,
                itemBuilder: (context, position) {
                  // Listed in the order they'll really play, which differs in shuffle.
                  final i = order[position];
                  final song = player.queue[i];
                  final isCurrent = i == player.index;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: kPagePadding,
                    ),
                    leading: CoverArt(
                      coverArtId: song.coverArtId,
                      size: 44,
                      radius: YomiRadius.art,
                      seed: song.album,
                    ),
                    title: Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: yomiText(
                        15,
                        weight: FontWeight.w700,
                        color: isCurrent
                            ? context.accent
                            : YomiColors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: yomiText(
                        12.5,
                        weight: FontWeight.w500,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                    trailing: isCurrent
                        ? EqualizerBars(isPlaying: player.isPlaying)
                        : null,
                    onTap: () {
                      player.jumpTo(i);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
