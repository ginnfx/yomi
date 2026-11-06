import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/export/wanted_export.dart';
import '../../core/reports/reports_api.dart';
import '../../state/reports_controller.dart';
import '../theme.dart';
import 'share_exported_file.dart';
import 'youtube_play_button.dart';

/// How many to show before "Show all".
const int _shownAtFirst = 5;

/// Every song anyone has asked for that the library doesn't have, most wanted first. It
/// says how many people want each one, but never who.
class WantedSongsSection extends StatefulWidget {
  const WantedSongsSection({super.key, this.shareFile});

  /// Hands a file to the phone's share sheet. Replaced in tests.
  final Future<void> Function(BuildContext context, ExportedFile file)?
  shareFile;

  @override
  State<WantedSongsSection> createState() => _WantedSongsSectionState();
}

class _WantedSongsSectionState extends State<WantedSongsSection> {
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    // After the first frame, so it never changes what's showing mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ReportsController>().refreshWanted();
    });
  }

  Future<void> _export(List<WantedSong> wanted) async {
    final format = await showModalBottomSheet<_Choice>(
      context: context,
      // Sizes to its rows instead of the default half-screen cap, which clips them on
      // short screens.
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: YomiColors.surface,
      builder: (_) => const _ExportChoices(),
    );
    if (format == null || !mounted) return;
    if (format == _Choice.copy) {
      final messenger = ScaffoldMessenger.of(context);
      await Clipboard.setData(
        ClipboardData(text: exportWanted(wanted, WantedFormat.text).content),
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Copied ${wanted.length} songs')),
      );
      return;
    }
    final file = exportWanted(wanted, format.format!);
    await (widget.shareFile ?? shareExportedFile)(context, file);
  }

  @override
  Widget build(BuildContext context) {
    final wanted = context.watch<ReportsController>().wanted;
    if (wanted.isEmpty) return const SizedBox.shrink();
    final shown = _showAll ? wanted : wanted.take(_shownAtFirst).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, YomiSpace.xl, 4, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Wanted by everyone',
                  style: yomiText(16, weight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Export list',
                icon: const Icon(Icons.ios_share_rounded),
                onPressed: () => _export(wanted),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 4),
          child: Text(
            '${wanted.length} songs people have asked for that aren\'t in the '
            'library yet. Upload one and it drops off this list.',
            style: yomiText(13, color: YomiColors.textSecondary),
          ),
        ),
        for (final song in shown)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: kPagePadding,
            ),
            leading: const Icon(Icons.music_note_rounded),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: yomiText(15, weight: FontWeight.w700),
            ),
            subtitle: Text(
              song.count > 1
                  ? '${song.artist} · ${song.count} people want this'
                  : song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: YoutubePlayButton(artist: song.artist, title: song.title),
          ),
        if (wanted.length > _shownAtFirst)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding - 8),
            child: TextButton(
              onPressed: () => setState(() => _showAll = !_showAll),
              child: Text(
                _showAll ? 'Show fewer' : 'Show all ${wanted.length}',
              ),
            ),
          ),
      ],
    );
  }
}

/// What the export sheet can hand back.
enum _Choice {
  text('Text file', 'One "Artist - Title" per line (.txt)', WantedFormat.text),
  csv(
    'Spreadsheet',
    'Artist, title and how many want it (.csv)',
    WantedFormat.csv,
  ),
  json('JSON', 'For scripts and other tools (.json)', WantedFormat.json),
  copy('Copy as text', 'Paste it straight into another app', null);

  const _Choice(this.label, this.hint, this.format);
  final String label;
  final String hint;
  final WantedFormat? format;
}

class _ExportChoices extends StatelessWidget {
  const _ExportChoices();

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              0,
              kPagePadding,
              8,
            ),
            child: Text(
              'Export wanted songs',
              style: yomiText(20, weight: FontWeight.w800),
            ),
          ),
          for (final choice in _Choice.values)
            ListTile(
              title: Text(choice.label),
              subtitle: Text(choice.hint),
              onTap: () => Navigator.pop(context, choice),
            ),
        ],
      ),
    ),
  );
}
