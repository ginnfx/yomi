import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'cover_color.dart';

const double _sheetRadius = 28;
const double _sheetBlur = 30;
const double _sheetMaxHeightShare = 0.88;
const double _tintStrength = 0.28;

/// One row of an action sheet.
class SheetAction {
  const SheetAction({
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

/// A frosted, floating sheet of actions tinted with a cover's colour, like Spotify's
/// ⋯ menus. Picking an action closes the sheet first, then runs it.
Future<void> showActionSheet(
  BuildContext context, {
  required Widget header,
  required List<SheetAction> actions,
  String? coverArtId,
  String? imageUrl,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: false,
  backgroundColor: Colors.transparent,
  elevation: 0,
  builder: (sheetContext) => _ActionSheet(
    coverArtId: coverArtId,
    imageUrl: imageUrl,
    header: header,
    actions: actions,
    onSelected: (action) {
      Navigator.pop(sheetContext);
      action.onSelected();
    },
  ),
);

/// The picture, title and subtitle at the top of an action sheet.
class SheetHeader extends StatelessWidget {
  const SheetHeader({
    super.key,
    required this.cover,
    required this.title,
    required this.subtitle,
  });

  final Widget cover;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
      child: Row(
        children: [
          cover,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(16, weight: FontWeight.w700),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: yomiText(
                      13,
                      weight: FontWeight.w500,
                      color: YomiColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({
    required this.coverArtId,
    required this.imageUrl,
    required this.header,
    required this.actions,
    required this.onSelected,
  });

  final String? coverArtId;
  final String? imageUrl;
  final Widget header;
  final List<SheetAction> actions;
  final ValueChanged<SheetAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * _sheetMaxHeightShare;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YomiSpace.s,
        0,
        YomiSpace.s,
        YomiSpace.s,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_sheetRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: _sheetBlur, sigmaY: _sheetBlur),
          child: CoverColorBuilder(
            coverArtId: coverArtId,
            imageUrl: imageUrl,
            builder: (context, color) => DecoratedBox(
              decoration: BoxDecoration(
                color: Color.lerp(
                  YomiColors.surface,
                  color ?? YomiColors.surface,
                  _tintStrength,
                )!.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(_sheetRadius),
                border: Border.all(color: YomiColors.faint(0.08)),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _Handle(),
                      header,
                      Divider(height: 1, color: YomiColors.faint(0.10)),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          children: [
                            for (final action in actions)
                              _ActionRow(
                                action: action,
                                onTap: () => onSelected(action),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: YomiColors.faint(0.3),
        borderRadius: BorderRadius.circular(YomiRadius.pill),
      ),
    ),
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action, required this.onTap});

  final SheetAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(action.icon, size: 26, color: YomiColors.faint(0.85)),
            const SizedBox(width: 18),
            Expanded(
              child: Text(
                action.label,
                style: yomiText(16, weight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
