import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

const double kNavBarHeight = 56;

class NavItem {
  const NavItem(this.icon, this.selectedIcon, this.label);

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Flat bottom navigation with every label always visible.
class YomiNavBar extends StatelessWidget {
  const YomiNavBar({
    super.key,
    required this.items,
    required this.index,
    required this.onSelected,
  });

  final List<NavItem> items;
  final int index;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kNavBarHeight,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: _NavButton(
                item: items[i],
                isSelected: i == index,
                onTap: () {
                  if (i != index) HapticFeedback.selectionClick();
                  onSelected(i);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final NavItem item;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected
        ? YomiColors.textPrimary
        : YomiColors.textSecondary;
    return Semantics(
      button: true,
      selected: isSelected,
      label: item.label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 40,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSelected ? item.selectedIcon : item.icon,
              color: color,
              size: 24,
            ),
            const SizedBox(height: 2),
            Text(item.label, style: yomiText(11, color: color)),
          ],
        ),
      ),
    );
  }
}
