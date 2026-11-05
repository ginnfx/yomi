import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/listening/wrapped_window.dart';

import '../../core/listening/history_api.dart';
import '../../core/listening/listening_stats.dart';
import '../../state/ai_controller.dart';
import '../../state/listening_log.dart';
import '../theme.dart';
import 'wrapped_page.dart';

const double _chartHeight = 96;
const int _topShown = 5;
const List<int> _labelledHours = [0, 6, 12, 18];

/// Works out stats, using AI labels for moods when there are any.
ListeningStats statsFor(
  BuildContext context,
  StatsRange range, {
  DateTime? now,
}) {
  final log = context.read<ListeningLog>();
  final ai = context.read<AiController>();
  return computeStats(
    log.events,
    range: range,
    now: now ?? DateTime.now(),
    imported: log.imported,
    moodsOf: (ListenEvent event) =>
        ai.tagForNames(event.artist, event.title)?.moods ?? const [],
  );
}

/// Your listening in numbers.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, this.now});

  /// Fixes the clock in tests.
  final DateTime? now;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late final DateTime _now = widget.now ?? DateTime.now();
  late StatsRange _range = StatsRange.year(_now.year);

  List<int> _years(ListeningLog log) {
    final years = {
      _now.year,
      for (final event in log.events) event.at.year,
      ...log.imported.years,
    }.toList()..sort((a, b) => b.compareTo(a));
    return years;
  }

  @override
  Widget build(BuildContext context) {
    final log = context.watch<ListeningLog>();
    final stats = statsFor(context, _range, now: _now);
    final year = _range.year;
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text('Stats', style: yomiText(20, weight: FontWeight.w800)),
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _RangeChips(
              range: _range,
              years: _years(log),
              now: _now,
              onChanged: (range) => setState(() => _range = range),
            ),
            if (stats.isEmpty)
              Padding(
                padding: const EdgeInsets.all(48),
                child: Text(
                  'Nothing played in this period yet.',
                  textAlign: TextAlign.center,
                  style: yomiText(
                    14,
                    weight: FontWeight.w500,
                    color: YomiColors.textSecondary,
                  ),
                ),
              )
            else ...[
              if (year != null &&
                  _range.month == null &&
                  isWrappedOpen(year, DateTime.now()))
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kPagePadding,
                    8,
                    kPagePadding,
                    0,
                  ),
                  child: FilledButton.icon(
                    onPressed: () => openWrapped(context, year),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text('Your $year Wrapped'),
                  ),
                ),
              _Tiles(stats: stats),
              _HourChart(byHour: stats.byHour),
              _TopList(
                title: 'Top songs',
                rows: [
                  for (final song in stats.topSongs.take(_topShown))
                    ('${song.title} · ${song.artist}', song.plays),
                ],
              ),
              _TopList(
                title: 'Top artists',
                rows: [
                  for (final artist in stats.topArtists.take(_topShown))
                    (artist.name, artist.plays),
                ],
              ),
              _TopList(
                title: 'Top genres',
                rows: [
                  for (final genre in stats.topGenres.take(_topShown))
                    (genre.name, genre.plays),
                ],
              ),
              _TopList(
                title: 'Top moods',
                rows: [
                  for (final mood in stats.topMoods.take(_topShown))
                    (mood.name, mood.plays),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RangeChips extends StatelessWidget {
  const _RangeChips({
    required this.range,
    required this.years,
    required this.now,
    required this.onChanged,
  });

  final StatsRange range;
  final List<int> years;
  final DateTime now;
  final ValueChanged<StatsRange> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, StatsRange value) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: value.year == range.year && value.month == range.month,
        onSelected: (_) => onChanged(value),
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
      child: Row(
        children: [
          chip('This month', StatsRange.month(now.year, now.month)),
          for (final year in years) chip('$year', StatsRange.year(year)),
          chip('All time', const StatsRange.all()),
        ],
      ),
    );
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.stats});

  final ListeningStats stats;

  @override
  Widget build(BuildContext context) {
    Widget tile(String value, String label) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: YomiColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              child: Text(value, style: yomiText(22, weight: FontWeight.w800)),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: yomiText(
                12,
                weight: FontWeight.w600,
                color: YomiColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 14, kPagePadding, 0),
      child: Row(
        children: [
          tile(formatCount(stats.minutes), 'minutes'),
          const SizedBox(width: 10),
          tile(formatCount(stats.plays), 'plays'),
          const SizedBox(width: 10),
          tile('${stats.longestStreak}', 'best streak (days)'),
        ],
      ),
    );
  }
}

/// Thousands separators, so big totals stay readable.
String formatCount(int value) {
  final digits = '$value';
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// One series, so one colour and no legend: the title says what it is.
class _HourChart extends StatelessWidget {
  const _HourChart({required this.byHour});

  final List<int> byHour;

  @override
  Widget build(BuildContext context) {
    final peak = byHour.reduce((a, b) => a > b ? a : b);
    final busiest = byHour.indexOf(peak);
    return Semantics(
      label: 'Plays by hour of the day. Busiest at ${formatHour(busiest)}.',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kPagePadding, 22, kPagePadding, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'When you listen',
              style: yomiText(16, weight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: _chartHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var hour = 0; hour < byHour.length; hour++)
                    Expanded(
                      child: Tooltip(
                        message: '${formatHour(hour)}: ${byHour[hour]} plays',
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            height: peak == 0
                                ? 0
                                : _chartHeight * byHour[hour] / peak,
                            decoration: BoxDecoration(
                              color: context.accent,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final hour in _labelledHours)
                  Expanded(
                    child: Text(
                      formatHour(hour),
                      style: yomiText(
                        11,
                        weight: FontWeight.w500,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String formatHour(int hour) => switch (hour) {
  0 => '12 am',
  12 => '12 pm',
  < 12 => '$hour am',
  _ => '${hour - 12} pm',
};

class _TopList extends StatelessWidget {
  const _TopList({required this.title, required this.rows});

  final String title;
  final List<(String, int)> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 22, kPagePadding, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: yomiText(16, weight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final (i, row) in rows.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      '${i + 1}',
                      style: yomiText(
                        13,
                        weight: FontWeight.w700,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: yomiText(14, weight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatCount(row.$2),
                    style: yomiText(
                      13,
                      weight: FontWeight.w600,
                      color: YomiColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
