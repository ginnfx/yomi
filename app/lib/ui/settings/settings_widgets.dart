import 'package:flutter/material.dart';

import '../theme.dart';

/// Small building blocks shared by every settings section.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.footer,
  });

  final String title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 22, kPagePadding, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              title.toUpperCase(),
              style: yomiText(
                12,
                weight: FontWeight.w800,
                color: context.accent,
                letterSpacing: 1.3,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: YomiColors.surface,
              borderRadius: BorderRadius.circular(22),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Material(
              type: MaterialType.transparency,
              child: Column(children: children),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              child: Text(
                footer!,
                style: yomiText(
                  12.5,
                  weight: FontWeight.w500,
                  color: YomiColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      activeThumbColor: context.onAccent,
      activeTrackColor: context.accent,
      title: Text(title, style: yomiText(15, weight: FontWeight.w700)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: yomiText(
                12.5,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
    );
  }
}

class SettingsInfoRow extends StatelessWidget {
  const SettingsInfoRow({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: YomiColors.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: yomiText(15, weight: FontWeight.w700)),
                Text(
                  detail,
                  style: yomiText(
                    12.5,
                    weight: FontWeight.w500,
                    color: YomiColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// Wrap of selectable pills, used for cache size and similar small choices.
class ChoicePills<T> extends StatelessWidget {
  const ChoicePills({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final value in values)
          ChoiceChip(
            label: Text(label(value)),
            selected: selected == value,
            showCheckmark: false,
            selectedColor: context.accent,
            backgroundColor: YomiColors.surfaceHigh,
            side: BorderSide.none,
            labelStyle: yomiText(
              13,
              weight: FontWeight.w700,
              color: selected == value
                  ? context.onAccent
                  : YomiColors.textPrimary,
            ),
            onSelected: (_) => onSelected(value),
          ),
      ],
    );
  }
}
