import 'package:flutter/material.dart';

import '../theme.dart';
import 'cover_art.dart';

class MusicShortcut {
  const MusicShortcut({
    required this.title,
    required this.subtitle,
    required this.coverArtId,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final String? coverArtId;
  final VoidCallback onTap;
}

/// Desktop shortcuts keep their height as the window grows.
class CompactMusicGrid extends StatelessWidget {
  const CompactMusicGrid({super.key, required this.items});
  final List<MusicShortcut> items;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1080
          ? 3
          : constraints.maxWidth >= 560
          ? 2
          : 1;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: 76,
          mainAxisSpacing: 8,
          crossAxisSpacing: 12,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => _Shortcut(item: items[i]),
      );
    },
  );
}

class _Shortcut extends StatefulWidget {
  const _Shortcut({required this.item});
  final MusicShortcut item;
  @override
  State<_Shortcut> createState() => _ShortcutState();
}

class _ShortcutState extends State<_Shortcut> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered ? YomiColors.faint(0.09) : YomiColors.faint(0.035),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: item.onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                CoverArt(
                  coverArtId: item.coverArtId,
                  size: 54,
                  radius: 8,
                  seed: item.title,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: yomiText(13, weight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: yomiText(11, color: YomiColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedOpacity(
                  opacity: _hovered ? 1 : 0.35,
                  duration: const Duration(milliseconds: 140),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: context.accent,
                    size: 24,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
