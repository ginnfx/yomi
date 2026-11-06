import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/cover_palette.dart';
import '../state/appearance_controller.dart';
import '../state/player_controller.dart';
import '../state/session.dart';
import 'theme.dart';

/// Lightness and least saturation an accent taken from a cover gets, so it reads on
/// both dark and light pages and stays colourful even for greyish art.
const double _coverAccentLightness = 0.62;
const double _coverAccentMinSaturation = 0.45;

/// Turns a cover's deep background colour into a bright accent.
Color accentFromCoverColor(Color cover) {
  final hsl = HSLColor.fromColor(cover);
  return hsl
      .withLightness(_coverAccentLightness)
      .withSaturation(hsl.saturation.clamp(_coverAccentMinSaturation, 1))
      .toColor();
}

/// Sits right inside MaterialApp: applies the theme's brightness to [YomiColors],
/// the chosen text size, reduce motion, and the accent (from the playing cover when
/// asked for), and hands them to every page through [YomiTheme].
class AppearanceScope extends StatefulWidget {
  const AppearanceScope({super.key, required this.child});

  final Widget child;

  @override
  State<AppearanceScope> createState() => _AppearanceScopeState();
}

class _AppearanceScopeState extends State<AppearanceScope> {
  Brightness? _applied;
  String? _coverId;
  Color? _coverAccent;

  /// [YomiColors] are read directly by many widgets that don't depend on anything
  /// that changes, so a brightness switch repaints the whole tree once.
  void _applyBrightness(Brightness brightness) {
    if (_applied == brightness) return;
    final isFirst = _applied == null;
    _applied = brightness;
    YomiColors.useBrightness(brightness);
    if (isFirst) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void rebuild(Element element) {
        element.markNeedsBuild();
        element.visitChildren(rebuild);
      }

      (context as Element).visitChildren(rebuild);
    });
  }

  void _followCover(AppearanceController look) {
    if (!look.accentFromCover) return;
    final player = context.watch<PlayerController>();
    final coverId = player.current?.coverArtId;
    if (coverId == _coverId) return;
    _coverId = coverId;
    final palette = context.read<CoverPalette>();
    final known = palette.peek(coverId);
    if (known != null || coverId == null) {
      _coverAccent = known == null ? null : accentFromCoverColor(known);
      return;
    }
    final session = context.read<SessionController>();
    if (!session.isSignedIn) return;
    palette.colorFor(session.client, coverId).then((color) {
      if (!mounted || _coverId != coverId) return;
      setState(
        () => _coverAccent = color == null ? null : accentFromCoverColor(color),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final look = context.watch<AppearanceController>();
    final brightness = Theme.of(context).brightness;
    _applyBrightness(brightness);
    _followCover(look);
    final media = MediaQuery.of(context);
    final cover = look.accentFromCover ? _coverAccent : null;
    final reduceMotion = look.reduceMotion || media.disableAnimations;
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(
          media.textScaler.scale(1) * look.textScale,
        ),
      ),
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: cover ?? look.palette.accent),
        duration: reduceMotion ? Duration.zero : YomiMotion.slow,
        curve: YomiMotion.curve,
        builder: (context, accent, _) => YomiTheme(
          palette: cover == null && accent == look.palette.accent
              ? look.palette
              : AccentPalette.fromColor(accent ?? look.palette.accent),
          isTrueBlack: look.isTrueBlack,
          brightness: brightness,
          reduceMotion: reduceMotion,
          child: widget.child,
        ),
      ),
    );
  }
}
