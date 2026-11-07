import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/messaging/messaging_api.dart';
import '../../core/messaging/share_info.dart';
import '../../state/catalog_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import 'cover_art.dart';

const double _coverSize = 64;

/// A shared song, album or playlist with its cover, title and artist, the way
/// Yomi shows suggestions. The cover fades in once found; until then the card
/// already has its final size, so nothing jumps.
class MessageShareCard extends StatefulWidget {
  const MessageShareCard({
    super.key,
    required this.message,
    required this.isMine,
    required this.onOpen,
  });

  final ChatMessage message;
  final bool isMine;
  final VoidCallback onOpen;

  @override
  State<MessageShareCard> createState() => _MessageShareCardState();
}

class _MessageShareCardState extends State<MessageShareCard> {
  static final Map<String, Future<ShareInfo?>> _remembered = {};

  late Future<ShareInfo?> _info;

  @override
  void initState() {
    super.initState();
    _info = _resolve();
  }

  Future<ShareInfo?> _resolve() {
    final session = context.read<SessionController>();
    final message = widget.message;
    final key =
        '${session.username}|${message.songId}|${message.albumId}|${message.playlistId}';
    final library = context.read<CatalogController>().songs;
    final found = _remembered.putIfAbsent(
      key,
      () => loadShareInfo(message, session.client, library: library),
    );
    // A share that couldn't be found is looked up again next time.
    found.then((info) {
      if (info == null) _remembered.remove(key);
    });
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final kind = shareKindOf(message) ?? ShareKind.song;
    final onAccent = widget.isMine;
    final foreground = onAccent ? context.onAccent : YomiColors.textPrimary;
    final secondary = foreground.withValues(alpha: 0.7);
    return FutureBuilder<ShareInfo?>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final title = info?.title ?? message.songTitle ?? 'Shared with you';
        final subtitle = info?.subtitle ?? _fallbackSubtitle(kind);
        return Semantics(
          button: true,
          label: 'Shared ${kind.name}: $title, $subtitle',
          excludeSemantics: true,
          child: InkWell(
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.all(YomiSpace.s),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(YomiRadius.card),
                    child: AnimatedSwitcher(
                      duration: context.motion(YomiMotion.standard),
                      child: CoverArt(
                        key: ValueKey(info?.coverArtId),
                        coverArtId: info?.coverArtId,
                        size: _coverSize,
                        radius: YomiRadius.card,
                        seed: title,
                      ),
                    ),
                  ),
                  const SizedBox(width: YomiSpace.m),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: yomiText(
                            15,
                            weight: FontWeight.w800,
                            color: foreground,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: yomiText(
                            12.5,
                            weight: FontWeight.w500,
                            color: secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: YomiSpace.s),
                  Icon(
                    kind == ShareKind.song
                        ? Icons.play_circle_rounded
                        : Icons.chevron_right_rounded,
                    size: 30,
                    color: foreground,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _fallbackSubtitle(ShareKind kind) => switch (kind) {
    ShareKind.song => 'Song',
    ShareKind.album => 'Album',
    ShareKind.playlist => 'Playlist',
  };
}
