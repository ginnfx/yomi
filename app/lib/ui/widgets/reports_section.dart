import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/messaging/music_to_send.dart';
import '../../core/reports/reports_api.dart';
import '../../state/reports_controller.dart';
import '../../state/youtube_controller.dart';
import '../theme.dart';
import 'song_picker_sheet.dart';

/// How many finished reports to keep showing under the open ones.
const int _closedShown = 10;

/// "Needs fixing" for the server admin, "My requests" for everyone else.
class ReportsSection extends StatefulWidget {
  const ReportsSection({super.key});

  @override
  State<ReportsSection> createState() => _ReportsSectionState();
}

class _ReportsSectionState extends State<ReportsSection> {
  @override
  void initState() {
    super.initState();
    // After the first frame: refreshing notifies listeners, which can't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<ReportsController>().refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final reports = context.watch<ReportsController>();
    final open = reports.open;
    final closed = [
      for (final report in reports.reports)
        if (!report.isOpen) report,
    ].take(_closedShown).toList();
    final title = reports.isAdmin ? 'Needs fixing' : 'My requests';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: yomiText(18, weight: FontWeight.w800)),
            ),
            if (reports.isLoading)
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: YomiSpace.s),
        if (reports.error != null && reports.reports.isEmpty)
          Text(reports.error!, style: yomiText(13, color: YomiColors.danger))
        else if (open.isEmpty && closed.isEmpty)
          Text(
            reports.isAdmin
                ? 'Nothing to fix. Reports from the song menu show up here.'
                : 'Report a song from its menu: a clean version, a missing cover, anything.',
            style: yomiText(13, color: YomiColors.textSecondary),
          ),
        for (final kind in ReportKind.values)
          ..._group(context, kind, open, reports),
        if (closed.isNotEmpty) ...[
          const SizedBox(height: YomiSpace.m),
          Text(
            'Done',
            style: yomiText(
              14,
              weight: FontWeight.w700,
              color: YomiColors.textSecondary,
            ),
          ),
          for (final report in closed)
            _ReportRow(report: report, isAdmin: reports.isAdmin),
        ],
      ],
    );
  }

  List<Widget> _group(
    BuildContext context,
    ReportKind kind,
    List<SongReport> open,
    ReportsController reports,
  ) {
    final ofKind = [
      for (final report in open)
        if (report.kind == kind) report,
    ];
    if (ofKind.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: YomiSpace.m),
        child: Text(
          '${kind.label} · ${ofKind.length}',
          style: yomiText(
            14,
            weight: FontWeight.w700,
            color: YomiColors.textSecondary,
          ),
        ),
      ),
      for (final report in ofKind)
        _ReportRow(report: report, isAdmin: reports.isAdmin),
    ];
  }
}

class _ReportRow extends StatelessWidget {
  const _ReportRow({required this.report, required this.isAdmin});

  final SongReport report;
  final bool isAdmin;

  bool get _canFetch =>
      report.kind == ReportKind.missingSong ||
      report.kind == ReportKind.explicitWanted;

  String get _detail {
    final parts = <String>[
      if (report.artist.isNotEmpty) report.artist,
      if (isAdmin && report.count > 1) 'asked by ${report.count}',
      if (report.isAuto) 'found by the server',
      if (!report.isOpen) report.resolution ?? _statusLabel(report.status),
      ...report.notes,
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(
      report.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: yomiText(15, weight: FontWeight.w700),
    ),
    subtitle: Text(_detail, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: !isAdmin || !report.isOpen
        ? _StatusChip(status: report.status)
        : PopupMenuButton<VoidCallback>(
            tooltip: 'Actions',
            onSelected: (action) => action(),
            itemBuilder: (menuContext) => [
              if (_canFetch &&
                  (Provider.of<YoutubeController?>(
                        context,
                        listen: false,
                      )?.isAvailable ??
                      false))
                PopupMenuItem(
                  value: () => _playFromYoutube(context),
                  child: const Text('Play from YouTube'),
                ),
              if (report.kind == ReportKind.explicitWanted &&
                  report.songId != null)
                PopupMenuItem(
                  value: () => _replace(context),
                  child: const Text('Replace with a song…'),
                ),
              PopupMenuItem(
                value: () => _close(context, isFixed: true),
                child: const Text('Mark fixed'),
              ),
              PopupMenuItem(
                value: () => _close(context, isFixed: false),
                child: const Text('Dismiss'),
              ),
            ],
          ),
  );

  /// Plays it here; Save to library on the player then closes a song request.
  Future<void> _playFromYoutube(BuildContext context) async {
    final youtube = context.read<YoutubeController>();
    final messenger = ScaffoldMessenger.of(context);
    final isPlaying = await youtube.play(
      artist: report.artist,
      title: report.title,
      wantExplicit: report.kind == ReportKind.explicitWanted,
    );
    if (!isPlaying) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            youtube.stateFor(report.artist, report.title)?.error ??
                "Couldn't play it.",
          ),
        ),
      );
    }
  }

  Future<void> _close(BuildContext context, {required bool isFixed}) async {
    final reports = context.read<ReportsController>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await reports.close(report, isFixed: isFixed)) {
      messenger.showSnackBar(
        SnackBar(content: Text(reports.error ?? 'Could not update it.')),
      );
    }
  }

  /// The better copy must already be in the library; the old file is archived.
  Future<void> _replace(BuildContext context) async {
    final reports = context.read<ReportsController>();
    final messenger = ScaffoldMessenger.of(context);
    final picked = await pickMusicToSend(context);
    if (picked is! PickedSong) return;
    final isDone = await reports.replace(report, newSongId: picked.song.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          isDone
              ? 'Replaced. The old copy is archived on the server.'
              : reports.error ?? 'Could not replace it.',
        ),
      ),
    );
  }
}

String _statusLabel(String status) => switch (status) {
  'resolved' => 'Fixed',
  'dismissed' => 'Left as it is',
  _ => 'Waiting',
};

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'resolved' => YomiColors.success,
      'dismissed' => YomiColors.textSecondary,
      _ => context.accent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(YomiRadius.pill),
        border: Border.all(color: color),
      ),
      child: Text(
        _statusLabel(status),
        style: yomiText(12, weight: FontWeight.w700, color: color),
      ),
    );
  }
}
