import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/session.dart';
import '../theme.dart';
import 'playlist_sheet.dart';

/// A heart that likes or unlikes [song] in one tap. It changes at once and goes back if
/// the server can't be reached.
class LikeButton extends StatefulWidget {
  const LikeButton({super.key, required this.song, this.size = 24});

  final Song song;
  final double size;

  @override
  State<LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<LikeButton> {
  late bool _isLiked = widget.song.isStarred;
  bool _isChanging = false;

  @override
  void didUpdateWidget(LikeButton old) {
    super.didUpdateWidget(old);
    // Another song, or the library says something different: trust that over our guess.
    if (old.song.id != widget.song.id ||
        old.song.isStarred != widget.song.isStarred) {
      _isLiked = widget.song.isStarred;
    }
  }

  Future<void> _toggle() async {
    if (_isChanging) return;
    final client = context.read<SessionController>().client;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final wasLiked = _isLiked;
    HapticFeedback.selectionClick();
    setState(() {
      _isLiked = !wasLiked;
      _isChanging = true;
    });
    try {
      await (wasLiked
          ? client.unstar(widget.song.id)
          : client.star(widget.song.id));
    } on Exception catch (error) {
      debugPrint('Could not change Liked for ${widget.song.id}: $error');
      if (mounted) setState(() => _isLiked = wasLiked);
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't change Liked songs")),
      );
    } finally {
      if (mounted) setState(() => _isChanging = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: _isLiked ? 'Unlike' : 'Like',
    iconSize: widget.size,
    color: _isLiked ? context.accent : null,
    onPressed: _toggle,
    icon: Icon(
      _isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
    ),
  );
}

/// A button that opens the "add to playlist" sheet for [song].
class AddToPlaylistButton extends StatelessWidget {
  const AddToPlaylistButton({super.key, required this.song, this.size = 24});

  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Add to playlist',
    iconSize: size,
    onPressed: () => showAddToPlaylist(context, song),
    icon: const Icon(Icons.add_circle_outline_rounded),
  );
}
