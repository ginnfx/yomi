import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../theme.dart';
import 'library_items.dart';
import 'library_tiles.dart';

const int _gridColumns = 3;
const double _gridSpacing = 14;
const double _gridTileAspect = 0.68;

/// The library's rows as a list or a grid. In the custom order, playlists can be
/// dragged into place with a long press, as on Spotify.
class LibraryList extends StatefulWidget {
  const LibraryList({
    super.key,
    required this.items,
    required this.isGrid,
    required this.canReorder,
    required this.emptyText,
    required this.onOpen,
    required this.onReorder,
  });

  final List<LibraryItem> items;
  final bool isGrid;
  final bool canReorder;
  final String emptyText;
  final ValueChanged<LibraryItem> onOpen;

  /// The playlists in their new order after a drag.
  final ValueChanged<List<Playlist>> onReorder;

  @override
  State<LibraryList> createState() => _LibraryListState();
}

class _LibraryListState extends State<LibraryList> {
  /// The order just dragged into, shown until the saved order comes back.
  List<PlaylistItem>? _dragged;

  @override
  void didUpdateWidget(LibraryList old) {
    super.didUpdateWidget(old);
    if (!identical(old.items, widget.items)) _dragged = null;
  }

  void _reorder(List<PlaylistItem> playlists, int from, int to) {
    final moved = [...playlists];
    moved.insert(to, moved.removeAt(from));
    setState(() => _dragged = moved);
    widget.onReorder([for (final item in moved) item.playlist]);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(40),
            child: Text(
              widget.emptyText,
              textAlign: TextAlign.center,
              style: yomiText(
                14,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
          ),
        ],
      );
    }
    if (widget.isGrid) return _grid(items);
    if (!widget.canReorder) {
      return ListView.builder(
        padding: const EdgeInsets.only(top: YomiSpace.xs, bottom: YomiSpace.l),
        itemCount: items.length,
        itemBuilder: (context, i) => LibraryRow(
          key: ValueKey(_keyOf(items[i])),
          item: items[i],
          onTap: () => widget.onOpen(items[i]),
        ),
      );
    }
    final fixed = [
      for (final item in items)
        if (item is! PlaylistItem) item,
    ];
    final playlists =
        _dragged ??
        [
          for (final item in items)
            if (item is PlaylistItem) item,
        ];
    return ListView(
      padding: const EdgeInsets.only(top: YomiSpace.xs, bottom: YomiSpace.l),
      children: [
        for (final item in fixed)
          LibraryRow(
            key: ValueKey(_keyOf(item)),
            item: item,
            onTap: () => widget.onOpen(item),
          ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => _reorder(playlists, from, to),
          proxyDecorator: (child, _, _) => Material(
            color: YomiColors.surfaceHigh,
            elevation: 6,
            child: child,
          ),
          itemCount: playlists.length,
          itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
            key: ValueKey(_keyOf(playlists[i])),
            index: i,
            child: LibraryRow(
              item: playlists[i],
              onTap: () => widget.onOpen(playlists[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _grid(List<LibraryItem> items) => GridView.builder(
    padding: const EdgeInsets.fromLTRB(
      kPagePadding,
      YomiSpace.s,
      kPagePadding,
      YomiSpace.l,
    ),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: _gridColumns,
      mainAxisSpacing: _gridSpacing,
      crossAxisSpacing: _gridSpacing,
      childAspectRatio: _gridTileAspect,
    ),
    itemCount: items.length,
    itemBuilder: (context, i) => LibraryGridTile(
      key: ValueKey(_keyOf(items[i])),
      item: items[i],
      onTap: () => widget.onOpen(items[i]),
    ),
  );

  static String _keyOf(LibraryItem item) => switch (item) {
    LikedSongsItem() => 'liked',
    DownloadedSongsItem() => 'downloaded',
    PlaylistItem(:final playlist) => 'playlist-${playlist.id}',
    ImportedItem(:final playlist) => 'imported-${playlist.id}',
    ArtistItem(:final artist) => 'artist-${artist.id}',
  };
}
