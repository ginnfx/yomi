import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// One set of neutral colours, for a dark or a light look.
@immutable
class YomiNeutrals {
  const YomiNeutrals({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.hairline,
    required this.textPrimary,
    required this.textSecondary,
  });

  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color hairline;
  final Color textPrimary;
  final Color textSecondary;

  static const dark = YomiNeutrals(
    background: Color(0xFF101012),
    surface: Color(0xFF1A1A1D),
    surfaceHigh: Color(0xFF28282C),
    hairline: Color(0x1AFFFFFF),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFA6A6AC),
  );

  static const light = YomiNeutrals(
    background: Color(0xFFF5F5F7),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE8E8ED),
    hairline: Color(0x1A000000),
    textPrimary: Color(0xFF111114),
    textSecondary: Color(0xFF5E5E66),
  );

  static YomiNeutrals of(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;
}

/// Yomi's look: flat neutral surfaces, strong type and the album art doing the
/// colour work. Neutrals follow the light or dark theme; the accent comes from the
/// chosen [AccentPalette] via `context.accent`.
abstract final class YomiColors {
  static YomiNeutrals _neutrals = YomiNeutrals.dark;

  /// Set by the app root whenever the theme's brightness changes.
  static void useBrightness(Brightness brightness) =>
      _neutrals = YomiNeutrals.of(brightness);

  static bool get isLight => identical(_neutrals, YomiNeutrals.light);

  static Color get background => _neutrals.background;
  static const trueBlack = Color(0xFF000000);
  static Color get surface => _neutrals.surface;
  static Color get surfaceHigh => _neutrals.surfaceHigh;
  static Color get hairline => _neutrals.hairline;
  static Color get textPrimary => _neutrals.textPrimary;
  static Color get textSecondary => _neutrals.textSecondary;

  /// The text colour at a lower strength, for icons and lines on page surfaces.
  static Color faint(double alpha) => textPrimary.withValues(alpha: alpha);
  static const success = Color(0xFF3FD694);
  static const danger = Color(0xFFFF6B6B);
}

/// Spacing scale. Anything off this scale should have a reason.
abstract final class YomiSpace {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii. Art stays nearly square; only people get circles.
abstract final class YomiRadius {
  static const double art = 6;
  static const double card = 8;
  static const double sheet = 16;
  static const double pill = 999;
}

/// Motion is quick and never overshoots.
abstract final class YomiMotion {
  static const quick = Duration(milliseconds: 140);
  static const standard = Duration(milliseconds: 240);
  static const slow = Duration(milliseconds: 420);
  static const Curve curve = Curves.easeOutCubic;
}

/// From this width up, pages use the sidebar and side-by-side layouts.
const double kWideLayoutWidth = 900;

/// One selectable colour scheme. Green is the default.
class AccentPalette {
  const AccentPalette(
    this.id,
    this.name,
    this.accent,
    this.deep,
    this.secondary,
  );

  /// A full palette grown from one colour: a darker shade and a neighbouring hue.
  factory AccentPalette.fromColor(
    Color color, {
    String id = kCustomPaletteId,
    String name = 'Custom',
  }) {
    final hsl = HSLColor.fromColor(color);
    final deep = hsl
        .withLightness((hsl.lightness * 0.45).clamp(0.12, 0.35))
        .toColor();
    final secondary = hsl.withHue((hsl.hue + 40) % 360).toColor();
    return AccentPalette(id, name, color, deep, secondary);
  }

  final String id;
  final String name;
  final Color accent;
  final Color deep;
  final Color secondary;

  @override
  bool operator ==(Object other) =>
      other is AccentPalette && other.id == id && other.accent == accent;

  @override
  int get hashCode => Object.hash(id, accent);
}

const String kCustomPaletteId = 'custom';

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
    this.brightness = Brightness.dark,
    this.reduceMotion = false,
    required super.child,
  });

  final AccentPalette palette;
  final bool isTrueBlack;
  final Brightness brightness;

  /// Animations should finish at once: the user or the system asked for less motion.
  final bool reduceMotion;

  static YomiTheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<YomiTheme>()!;

  static YomiTheme? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<YomiTheme>();

  /// Reads the theme without rebuilding when it changes; for routes and callbacks.
  static YomiTheme? peek(BuildContext context) =>
      context.getInheritedWidgetOfExactType<YomiTheme>();

  @override
  bool updateShouldNotify(YomiTheme old) =>
      palette != old.palette ||
      isTrueBlack != old.isTrueBlack ||
      brightness != old.brightness ||
      reduceMotion != old.reduceMotion;
}

extension YomiContext on BuildContext {
  bool get isWideLayout => MediaQuery.sizeOf(this).width >= kWideLayoutWidth;
  Color get accent => YomiTheme.of(this).palette.accent;
  Color get accentDeep => YomiTheme.of(this).palette.deep;
  Color get accentSecondary => YomiTheme.of(this).palette.secondary;

  /// A calmer mid-tone between the deep and bright accent; used for large surfaces like the hero card.
  Color get accentSoft => Color.lerp(
    YomiTheme.of(this).palette.deep,
    YomiTheme.of(this).palette.accent,
    0.55,
  )!;
  Color get pageColor {
    final theme = YomiTheme.of(this);
    return theme.isTrueBlack && theme.brightness == Brightness.dark
        ? YomiColors.trueBlack
        : YomiColors.background;
  }

  /// [duration], or no time at all when less motion was asked for.
  Duration motion(Duration duration) =>
      YomiTheme.maybeOf(this)?.reduceMotion ?? false ? Duration.zero : duration;
}

const double kPagePadding = 20;
const double kCardRadius = YomiRadius.card;
const String kFontFamily = 'Jakarta';

TextStyle yomiText(
  double size, {
  FontWeight weight = FontWeight.w600,
  Color? color,
  double? height,
  double? letterSpacing,
}) => TextStyle(
  fontFamily: kFontFamily,
  fontSize: size,
  fontWeight: weight,
  color: color ?? YomiColors.textPrimary,
  height: height,
  letterSpacing: letterSpacing,
);

ThemeData buildYomiTheme(
  AccentPalette palette, {
  bool trueBlack = false,
  Brightness brightness = Brightness.dark,
}) {
  final colors = YomiNeutrals.of(brightness);
  final isDark = brightness == Brightness.dark;
  final page = trueBlack && isDark ? YomiColors.trueBlack : colors.background;
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.accent,
    brightness: brightness,
    surface: page,
  ).copyWith(primary: palette.accent, onPrimary: Colors.black);
  final base =
      (isDark ? Typography.whiteMountainView : Typography.blackMountainView)
          .apply(
            fontFamily: kFontFamily,
            bodyColor: colors.textPrimary,
            displayColor: colors.textPrimary,
          );
  return ThemeData(
    useMaterial3: true,
    fontFamily: kFontFamily,
    colorScheme: scheme,
    textTheme: base,
    scaffoldBackgroundColor: page,
    canvasColor: page,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      foregroundColor: colors.textPrimary,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: colors.textPrimary.withValues(alpha: 0.2),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(YomiRadius.sheet),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(YomiRadius.sheet),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        textStyle: yomiText(15, weight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: palette.accent, width: 1.5),
      ),
      hintStyle: TextStyle(color: colors.textSecondary),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.surfaceHigh,
      contentTextStyle: yomiText(
        14,
        weight: FontWeight.w600,
        color: colors.textPrimary,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 5,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      activeTrackColor: colors.textPrimary,
      inactiveTrackColor: colors.textPrimary.withValues(alpha: 0.24),
      thumbColor: colors.textPrimary,
      overlayShape: SliderComponentShape.noOverlay,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

/// A flat page colour, or a vertical fade from [tint] when a page is about one album.
class PageBackground extends StatelessWidget {
  const PageBackground({
    super.key,
    required this.child,
    this.tint,
    this.strength = 0.6,
  });

  final Widget child;

  /// A colour washing down from the top, used only behind the player.
  final Color? tint;
  final double strength;

  @override
  Widget build(BuildContext context) {
    final page = context.pageColor;
    final color = tint;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: page,
        gradient: color == null
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.lerp(page, color, strength)!, page],
              ),
      ),
      child: child,
    );
  }
}

/// A page route with the platform's transition, or none when less motion was asked for.
PageRoute<T> yomiRoute<T>({
  required WidgetBuilder builder,
  bool fullscreenDialog = false,
}) => _YomiPageRoute<T>(builder: builder, fullscreenDialog: fullscreenDialog);

class _YomiPageRoute<T> extends MaterialPageRoute<T> {
  _YomiPageRoute({required super.builder, super.fullscreenDialog});

  bool get _isReduced {
    final context = navigator?.context;
    return context != null && (YomiTheme.peek(context)?.reduceMotion ?? false);
  }

  @override
  Duration get transitionDuration =>
      _isReduced ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _isReduced ? Duration.zero : super.reverseTransitionDuration;
}
