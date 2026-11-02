import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings.dart';
import '../theme.dart';
import 'settings_widgets.dart';

const Map<String, (String, String, IconData)> homeSectionInfo = {
  'shuffle': (
    'Shuffle everything',
    'The big button at the top',
    Icons.shuffle_rounded,
  ),
  'quick': (
    'Quick picks',
    'Your playlists and newest songs as tiles',
    Icons.grid_view_rounded,
  ),
  'recent': (
    'Recently added',
    'The newest songs, as a scrolling row',
    Icons.new_releases_outlined,
  ),
  'discover': (
    'Discover',
    'A random handful from the library',
    Icons.explore_outlined,
  ),
};

/// Lets the user switch Home sections on and off and drag them into a new order.
class HomeLayoutSection extends StatelessWidget {
  const HomeLayoutSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final order = settings.homeOrder;
    final hidden = settings.hiddenHomeSections;
    return SettingsGroup(
      title: 'Home screen',
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (from, to) {
            final next = [...order];
            final item = next.removeAt(from);
            next.insert(to > from ? to - 1 : to, item);
            settings.setHomeLayout(next, hidden);
          },
          children: [
            for (var i = 0; i < order.length; i++)
              ListTile(
                key: ValueKey(order[i]),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  homeSectionInfo[order[i]]!.$3,
                  color: hidden.contains(order[i])
                      ? YomiColors.textSecondary
                      : context.accent,
                ),
                title: Text(
                  homeSectionInfo[order[i]]!.$1,
                  style: yomiText(
                    15,
                    weight: FontWeight.w700,
                    color: hidden.contains(order[i])
                        ? YomiColors.textSecondary
                        : YomiColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  homeSectionInfo[order[i]]!.$2,
                  style: yomiText(
                    12.5,
                    weight: FontWeight.w500,
                    color: YomiColors.textSecondary,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: !hidden.contains(order[i]),
                      activeThumbColor: Colors.black,
                      activeTrackColor: context.accent,
                      onChanged: (visible) {
                        final nextHidden = {...hidden};
                        visible
                            ? nextHidden.remove(order[i])
                            : nextHidden.add(order[i]);
                        settings.setHomeLayout(order, nextHidden);
                      },
                    ),
                    ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.drag_handle_rounded,
                          color: YomiColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
