import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/appearance_controller.dart';
import '../theme.dart';
import 'settings_widgets.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<AppearanceController>();
    return SettingsGroup(
      title: 'Appearance',
      children: [
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final palette in accentPalettes)
                    _Swatch(
                      palette: palette,
                      isSelected: palette.id == appearance.palette.id,
                    ),
                ],
              ),
            ],
          ),
        ),
        SettingsSwitch(
          title: 'True black background',
          value: appearance.isTrueBlack,
          onChanged: appearance.setTrueBlack,
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.palette, required this.isSelected});

  final AccentPalette palette;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        context.read<AppearanceController>().setPalette(palette);
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
                color: isSelected ? Colors.white : Colors.transparent,
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
                  ? const Icon(
                      Icons.check_rounded,
                      color: Colors.black,
                      size: 22,
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            palette.name,
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
