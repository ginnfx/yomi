import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/listening/listening_stats.dart';
import '../theme.dart';
import 'stats_page.dart';

const double _shareImageScale = 3;

void openWrapped(BuildContext context, int year) {
  final stats = statsFor(context, StatsRange.year(year));
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => WrappedPage(year: year, stats: stats),
    ),
  );
}

/// What your listening says about your hours.
String listenerType(int hour) => switch (hour) {
  >= 5 && < 12 => 'Early riser',
  >= 12 && < 17 => 'Afternoon regular',
  >= 17 && < 22 => 'Evening listener',
  _ => 'Night owl',
};

/// A year of listening as a story, one idea to a page, ending in something to share.
class WrappedPage extends StatefulWidget {
  const WrappedPage({super.key, required this.year, required this.stats});

  final int year;
  final ListeningStats stats;

  @override
  State<WrappedPage> createState() => _WrappedPageState();
}

class _WrappedPageState extends State<WrappedPage> {
  final _shareCard = GlobalKey();
  bool _isSharing = false;

  Future<void> _share() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isSharing = true);
    try {
      final boundary =
          _shareCard.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: _shareImageScale);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/yomi-wrapped-${widget.year}.png');
      await file.writeAsBytes(data!.buffer.asUint8List());
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'My ${widget.year} on Yomi',
        ),
      );
    } on Object catch (error) {
      debugPrint('Could not share Wrapped: $error');
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't make the image to share")),
      );
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  List<Widget> _pages() {
    final stats = widget.stats;
    final hour = stats.busiestHour;
    final artists = stats.topArtists;
    return [
      _StoryPage(
        lead: 'Your ${widget.year} on Yomi',
        headline: '${formatCount(stats.minutes)} minutes',
        detail: '${formatCount(stats.plays)} plays. Here\'s what filled them.',
      ),
      if (artists.isNotEmpty)
        _StoryPage(
          lead: 'You kept coming back to',
          headline: artists.first.name,
          detail: '${formatCount(artists.first.plays)} plays',
        ),
      if (artists.length > 1)
        _StoryPage(
          lead: 'Your top artists',
          lines: [for (final artist in artists.take(5)) artist.name],
        ),
      if (stats.topSongs.isNotEmpty)
        _StoryPage(
          lead: 'Your song of the year',
          headline: stats.topSongs.first.title,
          detail:
              '${stats.topSongs.first.artist} · '
              '${formatCount(stats.topSongs.first.plays)} plays',
        ),
      if (stats.topSongs.length > 1)
        _StoryPage(
          lead: 'Your top songs',
          lines: [for (final song in stats.topSongs.take(5)) song.title],
        ),
      if (stats.topGenres.isNotEmpty)
        _StoryPage(
          lead: 'You lived in',
          headline: stats.topGenres.first.name,
          detail: 'more than anywhere else',
        ),
      if (stats.topMoods.isNotEmpty)
        _StoryPage(
          lead: 'Your year felt',
          headline: stats.topMoods.first.name,
          detail: 'most of the time',
        ),
      if (hour != null)
        _StoryPage(
          lead: 'You\'re a',
          headline: listenerType(hour),
          detail: 'Most plays around ${formatHour(hour)}',
        ),
      if (stats.longestStreak > 1)
        _StoryPage(
          lead: 'Your longest run',
          headline: '${stats.longestStreak} days',
          detail: 'in a row with music',
        ),
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          RepaintBoundary(
            key: _shareCard,
            child: _ShareCard(year: widget.year, stats: stats),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _isSharing ? null : _share,
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Share'),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: widget.stats.isEmpty
          ? Center(
              child: Text(
                'Nothing played in ${widget.year} yet.',
                style: yomiText(16, weight: FontWeight.w600),
              ),
            )
          : PageView(children: _pages()),
    );
  }
}

class _StoryPage extends StatelessWidget {
  const _StoryPage({
    required this.lead,
    this.headline,
    this.detail,
    this.lines = const [],
  });

  final String lead;
  final String? headline;
  final String? detail;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final big = headline;
    final small = detail;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lead,
            style: yomiText(
              18,
              weight: FontWeight.w600,
              color: YomiColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          if (big != null)
            Text(
              big,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: yomiText(
                44,
                weight: FontWeight.w800,
                color: context.accent,
                height: 1.05,
                letterSpacing: -1,
              ),
            ),
          for (final (i, line) in lines.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '${i + 1}. $line',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: yomiText(24, weight: FontWeight.w700),
              ),
            ),
          if (small != null) ...[
            const SizedBox(height: 14),
            Text(small, style: yomiText(16, weight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}

class _ShareCard extends StatelessWidget {
  const _ShareCard({required this.year, required this.stats});

  final int year;
  final ListeningStats stats;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: YomiColors.surfaceHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'My $year on Yomi',
            style: yomiText(20, weight: FontWeight.w800, color: context.accent),
          ),
          const SizedBox(height: 16),
          Text(
            '${formatCount(stats.minutes)} minutes',
            style: yomiText(26, weight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          for (final (i, song) in stats.topSongs.take(5).indexed)
            Text(
              '${i + 1}. ${song.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(14, weight: FontWeight.w600),
            ),
          const SizedBox(height: 12),
          for (final (i, artist) in stats.topArtists.take(3).indexed)
            Text(
              '${i + 1}. ${artist.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(
                14,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}
