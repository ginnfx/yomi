import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/cover_art.dart';

/// One row to drag into place.
@immutable
class ReorderItem {
  const ReorderItem({
    required this.title,
    required this.subtitle,
    this.coverArtId,
  });

  final String title;
  final String subtitle;
  final String? coverArtId;
}

/// Drag songs into a new order. Returns the new order as positions in [items], or null
/// if nothing changed.
Future<List<int>?> reorderSongs(
  BuildContext context, {
  required String title,
  required List<ReorderItem> items,
}) => Navigator.of(context).push<List<int>>(
  yomiRoute(
    builder: (_) => _ReorderPage(title: title, items: items),
  ),
);

class _ReorderPage extends StatefulWidget {
  const _ReorderPage({required this.title, required this.items});

  final String title;
  final List<ReorderItem> items;

  @override
  State<_ReorderPage> createState() => _ReorderPageState();
}

class _ReorderPageState extends State<_ReorderPage> {
  late List<int> _order = List.generate(widget.items.length, (i) => i);

  bool get _isChanged {
    for (var i = 0; i < _order.length; i++) {
      if (_order[i] != i) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title, style: yomiText(18, weight: FontWeight.w800)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _isChanged ? _order : null),
          child: const Text('Done'),
        ),
      ],
    ),
    body: ReorderableListView.builder(
      itemCount: _order.length,
      // The new position already allows for the dragged row leaving its old place.
      onReorderItem: (from, to) => setState(() {
        final next = [..._order];
        next.insert(to, next.removeAt(from));
        _order = next;
      }),
      itemBuilder: (context, row) {
        final item = widget.items[_order[row]];
        return ListTile(
          key: ValueKey(_order[row]),
          contentPadding: const EdgeInsets.symmetric(horizontal: kPagePadding),
          leading: CoverArt(
            coverArtId: item.coverArtId,
            size: 44,
            radius: YomiRadius.art,
            seed: item.title,
          ),
          title: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: yomiText(15, weight: FontWeight.w700),
          ),
          subtitle: Text(
            item.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: ReorderableDragStartListener(
            index: row,
            child: const Icon(Icons.drag_handle_rounded),
          ),
        );
      },
    ),
  );
}
