import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Yomi's look: deep ink background with a soft coloured glow, expressive type, big rounded art.
/// Neutral colours live here; the accent comes from the chosen [AccentPalette] via `context.accent`.
abstract final class YomiColors {
  static const background = Color(0xFF0A0A10);
  static const trueBlack = Color(0xFF000000);
  static const surface = Color(0xFF14141D);
  static const surfaceHigh = Color(0xFF1F1F2B);
  static const textPrimary = Color(0xFFF6F5FB);
  static const textSecondary = Color(0xFF9D9BB0);
  static const success = Color(0xFF6EE7B7);
}

/// One selectable colour scheme. Green is the default.
class AccentPalette {
  const AccentPalette(
    this.id,
    this.name,
    this.accent,
    this.deep,
    this.secondary,
  );

  final String id;
  final String name;
  final Color accent;
  final Color deep;
  final Color secondary;
}

const List<AccentPalette> accentPalettes = [
  AccentPalette(
    'green',
    'Green',
    Color(0xFF3FD694),
    Color(0xFF0B5D3F),
    Color(0xFF2AA89A),
  ),
  AccentPalette(
    'violet',
    'Violet',
    Color(0xFFB8A1FF),
    Color(0xFF4B3A9E),
    Color(0xFFE58FB8),
  ),
  AccentPalette(
    'rose',
    'Rose',
    Color(0xFFFF8FB8),
    Color(0xFF8E2A52),
    Color(0xFFE8A06A),
  ),
  AccentPalette(
    'sky',
    'Sky',
    Color(0xFF6CC4FF),
    Color(0xFF1D4F9C),
    Color(0xFF8D86E0),
  ),
  AccentPalette(
    'amber',
    'Amber',
    Color(0xFFFFC857),
    Color(0xFF8A4F00),
    Color(0xFFE5766E),
  ),
];

AccentPalette paletteById(String? id) => accentPalettes.firstWhere(
  (p) => p.id == id,
  orElse: () => accentPalettes.first,
);

/// Makes the chosen palette available to every widget; changing it repaints the app.
class YomiTheme extends InheritedWidget {
  const YomiTheme({
    super.key,
    required this.palette,
    required this.isTrueBlack,
    required super.child,
  });

  final AccentPalette palette;
  final bool isTrueBlack;

  static YomiTheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<YomiTheme>()!;

  @override
  bool updateShouldNotify(YomiTheme old) =>
      palette != old.palette || isTrueBlack != old.isTrueBlack;
}

extension YomiContext on BuildContext {
  Color get accent => YomiTheme.of(this).palette.accent;
  Color get accentDeep => YomiTheme.of(this).palette.deep;
  Color get accentSecondary => YomiTheme.of(this).palette.secondary;

  /// A calmer mid-tone between the deep and bright accent; used for large surfaces like the hero card.
  Color get accentSoft => Color.lerp(
    YomiTheme.of(this).palette.deep,
    YomiTheme.of(this).palette.accent,
    0.55,
  )!;
  Color get pageColor => YomiTheme.of(this).isTrueBlack
      ? YomiColors.trueBlack
      : YomiColors.background;

  LinearGradient get accentGradient {
    final p = YomiTheme.of(this).palette;
    return LinearGradient(
      colors: [p.deep, p.accent, p.secondary],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
  }
}

const double kPagePadding = 20;
const double kCardRadius = 16;
const String kFontFamily = 'Jakarta';

TextStyle yomiText(
  double size, {
  FontWeight weight = FontWeight.w600,
  Color color = YomiColors.textPrimary,
  double? height,
  double? letterSpacing,
}) => TextStyle(
  fontFamily: kFontFamily,
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: letterSpacing,
);

ThemeData buildYomiTheme(AccentPalette palette, {bool trueBlack = false}) {
  final page = trueBlack ? YomiColors.trueBlack : YomiColors.background;
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.accent,
    brightness: Brightness.dark,
    surface: page,
  ).copyWith(primary: palette.accent, onPrimary: Colors.black);
  final base = Typography.whiteMountainView.apply(
    fontFamily: kFontFamily,
    bodyColor: YomiColors.textPrimary,
    displayColor: YomiColors.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: kFontFamily,
    colorScheme: scheme,
    textTheme: base,
    scaffoldBackgroundColor: page,
    canvasColor: page,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: YomiColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: Color(0x33FFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: YomiColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        textStyle: yomiText(15, weight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: YomiColors.surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: palette.accent, width: 1.5),
      ),
      hintStyle: const TextStyle(color: YomiColors.textSecondary),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: YomiColors.surfaceHigh,
      contentTextStyle: yomiText(14, weight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 5,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      activeTrackColor: YomiColors.textPrimary,
      inactiveTrackColor: Colors.white24,
      thumbColor: YomiColors.textPrimary,
      overlayShape: SliderComponentShape.noOverlay,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// The soft colour wash behind a page: a smooth vertical fade, never a visible blob.
/// Ordinary pages get a whisper of the accent; album and player pages pass a stronger tint.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({
    super.key,
    required this.child,
    this.tint,
    this.strength,
  });

  final Widget child;
  final Color? tint;
  final double? strength;

  @override
  Widget build(BuildContext context) {
    final wash = tint ?? context.accentDeep;
    final amount = strength ?? (tint == null ? 0.22 : 0.55);
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: context.pageColor)),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 520,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    wash.withValues(alpha: amount),
                    wash.withValues(alpha: amount * 0.38),
                    wash.withValues(alpha: amount * 0.1),
                    wash.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.35, 0.7, 1],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
