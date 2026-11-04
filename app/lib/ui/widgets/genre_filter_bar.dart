import 'package:flutter/material.dart';

import '../../core/genres.dart';
import '../theme.dart';

/// A scrolling row of genre chips. Several can be on at once; none means everything.
class GenreFilterBar extends StatelessWidget {
  const GenreFilterBar({
    super.key,
    required this.groups,
    required this.selected,
    required this.onChanged,
  });

  final List<GenreGroup> groups;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: YomiSpace.s),
        itemBuilder: (context, i) {
          final name = groups[i].name;
          final isOn = selected.contains(name);
          return FilterChip(
            label: Text(name),
            selected: isOn,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            selectedColor: YomiColors.textPrimary,
            backgroundColor: YomiColors.surfaceHigh,
            side: BorderSide.none,
            labelStyle: yomiText(
              13,
              weight: FontWeight.w600,
              color: isOn ? Colors.black : YomiColors.textPrimary,
            ),
            onSelected: (_) => onChanged(
              isOn
                  ? selected.where((other) => other != name).toSet()
                  : {...selected, name},
            ),
          );
        },
      ),
    );
  }
}
