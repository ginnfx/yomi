import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/cover_palette.dart';
import '../../state/session.dart';
import '../theme.dart';

const Color _neutral = Color(0xFF202020);

/// Page background washed in the colour of the given cover art.
class TintedBackground extends StatelessWidget {
  const TintedBackground({
    super.key,
    required this.coverArtId,
    required this.child,
  });

  final String? coverArtId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final client = context.read<SessionController>().client;
    final palette = context.read<CoverPalette>();
    final known = palette.peek(coverArtId);
    // Until the cover's colour is known stay neutral; never flash the accent colour.
    final waiting = coverArtId != null ? _neutral : context.accentDeep;
    return FutureBuilder<Color?>(
      future: palette.colorFor(client, coverArtId),
      initialData: known,
      builder: (context, snapshot) => TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: snapshot.data ?? waiting),
        duration: known == null
            ? const Duration(milliseconds: 600)
            : Duration.zero,
        builder: (context, color, _) => PageBackground(
          tint: color,
          strength: snapshot.data == null ? 0.2 : 0.75,
          child: child,
        ),
      ),
    );
  }
}
