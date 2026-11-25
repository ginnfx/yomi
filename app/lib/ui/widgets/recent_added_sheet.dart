import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import 'song_tile.dart';

/// How many albums one page of the sheet asks for. Each album contributes all
/// of its songs, so a page is usually well over 30 songs.
const int _defaultAlbumsPerPage = 6;

/// Opens the songs added most recently, newest first, loading more as you scroll.
Future<void> showRecentlyAdded(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const RecentlyAddedSheet(),
    );

/// The newest songs in one paged list. Tap plays from that point; the ⋯ button
/// offers the same actions as a song anywhere else.
class RecentlyAddedSheet extends StatefulWidget {
  const RecentlyAddedSheet({
    super.key,
    this.albumsPerPage = _defaultAlbumsPerPage,
  });

  /// How many albums make up one page. Overridable so tests can page quickly.
  final int albumsPerPage;

  @override
  State<RecentlyAddedSheet> createState() => _RecentlyAddedSheetState();
}

class _RecentlyAddedSheetState extends State<RecentlyAddedSheet> {
  final _songs = <Song>[];
  final _seen = <String>{};
  final _scroll = ScrollController();
  var _offset = 0;
  var _hasMore = true;
  var _loading = false;
  var _started = false;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _scroll.addListener(_loadIfNearEnd);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _loadIfNearEnd() {
    // The bottom sheet can be measured before it has clients.
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 480) unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context
          .read<SessionController>()
          .client
          .recentSongsPage(
            albumsPerPage: widget.albumsPerPage,
            albumOffset: _offset,
          );
      if (!mounted) return;
      setState(() {
        _offset = page.nextOffset;
        _hasMore = page.hasMore;
        // A song can appear twice if an album shifts between pages.
        for (final song in page.songs) {
          if (_seen.add(song.id)) _songs.add(song);
        }
      });
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kPagePadding,
                4,
                kPagePadding,
                8,
              ),
              child: Text(
                'Recently added',
                style: yomiText(22, weight: FontWeight.w800),
              ),
            ),
            Flexible(child: _content(player)),
          ],
        ),
      ),
    );
  }

  Widget _content(PlayerController player) {
    if (_songs.isEmpty) {
      if (_loading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (_error != null) return _emptyError();
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Text(
          'Nothing new yet',
          textAlign: TextAlign.center,
          style: yomiText(14, color: YomiColors.textSecondary),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      shrinkWrap: true,
      padding: EdgeInsets.only(
        bottom: 12 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: _songs.length + 1,
      itemBuilder: (context, i) {
        if (i == _songs.length) return _footer();
        return SongTile(
          key: ValueKey(_songs[i].id),
          song: _songs[i],
          onTap: () => player.playQueue(List.of(_songs), startIndex: i),
        );
      },
    );
  }

  Widget _emptyError() => Padding(
    padding: const EdgeInsets.all(48),
    child: Column(
      children: [
        Text(
          "Couldn't load recent songs",
          textAlign: TextAlign.center,
          style: yomiText(15, weight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: _load, child: const Text('Try again')),
      ],
    ),
  );

  Widget _footer() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Text(
              "Couldn't load more",
              style: yomiText(13, color: YomiColors.textSecondary),
            ),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (!_hasMore) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Center(
        child: TextButton(
          key: const Key('recently-added-more'),
          onPressed: _load,
          child: const Text('Load more'),
        ),
      ),
    );
  }
}
