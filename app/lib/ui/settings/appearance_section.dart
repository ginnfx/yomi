import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/appearance_controller.dart';
import '../theme.dart';
import 'accent_picker_sheet.dart';
import 'app_icon_row.dart';
import 'settings_widgets.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<AppearanceController>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SettingsGroup(
      title: 'Appearance',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Theme', style: yomiText(15, weight: FontWeight.w700)),
              const SizedBox(height: 10),
              ChoicePills<ThemeMode>(
                values: const [
                  ThemeMode.system,
                  ThemeMode.light,
                  ThemeMode.dark,
                ],
                selected: appearance.themeMode,
                label: _themeLabel,
                onSelected: appearance.setThemeMode,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Accent colour',
                style: yomiText(15, weight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: YomiSpace.m,
                runSpacing: YomiSpace.m,
                children: [
                  for (final palette in accentPalettes)
                    _Swatch(
                      palette: palette,
                      isSelected: palette.id == appearance.palette.id,
                      onTap: () => appearance.setPalette(palette),
                    ),
                  _Swatch(
                    palette: appearance.customAccent == null
                        ? AccentPalette.fromColor(const Color(0xFF9E9EA8))
                        : appearance.palette,
                    label: 'Custom',
                    isSelected: appearance.customAccent != null,
                    onTap: () => pickCustomAccent(context),
                  ),
                ],
              ),
            ],
          ),
        ),
        SettingsSwitch(
          title: 'Colour from the playing song',
          subtitle: 'The accent follows the cover art',
          value: appearance.accentFromCover,
          onChanged: appearance.setAccentFromCover,
        ),
        if (isDark)
          SettingsSwitch(
            title: 'True black background',
            value: appearance.isTrueBlack,
            onChanged: appearance.setTrueBlack,
          ),
        const AppIconRow(),
        const _TextSizeRow(),
        SettingsSwitch(
          title: 'Reduce motion',
          subtitle: 'Skip animations between screens',
          value: appearance.reduceMotion,
          onChanged: appearance.setReduceMotion,
        ),
      ],
    );
  }
}

String _themeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'Automatic',
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
};

class _TextSizeRow extends StatelessWidget {
  const _TextSizeRow();

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<AppearanceController>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Text size', style: yomiText(15, weight: FontWeight.w700)),
          Row(
            children: [
              Text('A', style: yomiText(13, color: YomiColors.textSecondary)),
              Expanded(
                child: Slider(
                  value: appearance.textScale,
                  min: kMinTextScale,
                  max: kMaxTextScale,
                  divisions: 9,
                  label: '${(appearance.textScale * 100).round()}%',
                  onChanged: appearance.setTextScale,
                ),
              ),
              Text('A', style: yomiText(20, color: YomiColors.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.palette,
    required this.isSelected,
    required this.onTap,
    this.label,
  });

  final AccentPalette palette;
  final bool isSelected;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 52,
            height: 52,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? YomiColors.textPrimary : Colors.transparent,
                width: 2,
              ),
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [palette.deep, palette.accent, palette.secondary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: isSelected
                  ? Icon(Icons.check_rounded, color: palette.onAccent, size: 22)
                  : null,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label ?? palette.name,
            style: yomiText(
              12,
              weight: isSelected ? FontWeight.w800 : FontWeight.w600,
              color: isSelected
                  ? YomiColors.textPrimary
                  : YomiColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
