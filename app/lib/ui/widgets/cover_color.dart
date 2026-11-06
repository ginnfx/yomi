import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/cover_palette.dart';
import '../../state/session.dart';
import '../theme.dart';

/// Builds with the colour of a cover: a picture at [imageUrl] if given, otherwise the
/// album art [coverArtId]. The colour is null until known, then fades in.
class CoverColorBuilder extends StatelessWidget {
  const CoverColorBuilder({
    super.key,
    required this.coverArtId,
    required this.builder,
    this.imageUrl,
  });

  final String? coverArtId;
  final String? imageUrl;
  final Widget Function(BuildContext context, Color? color) builder;

  @override
  Widget build(BuildContext context) {
    final palette = context.read<CoverPalette>();
    final url = imageUrl;
    final key = url ?? coverArtId;
    final known = palette.peek(key);
    final future = url != null
        ? palette.colorForImage(url, () => NetworkImage(url))
        : palette.colorFor(context.read<SessionController>().client, key);
    return FutureBuilder<Color?>(
      future: future,
      initialData: known,
      builder: (context, snapshot) {
        final color = snapshot.data;
        if (color == null) return builder(context, null);
        return TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: color),
          duration: known == null
              ? context.motion(YomiMotion.slow)
              : Duration.zero,
          builder: (context, shown, _) => builder(context, shown),
        );
      },
    );
  }
}
