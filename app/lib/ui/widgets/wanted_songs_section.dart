import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/export/wanted_export.dart';
import '../../core/reports/reports_api.dart';
import '../../core/spotify/missing_songs.dart';
import '../../state/catalog_controller.dart';
import '../../state/imports_controller.dart';
import '../../state/reports_controller.dart';
import '../theme.dart';
import 'share_exported_file.dart';
import 'cover_art.dart';
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

  /// Asks for the list whenever it's wanted and nothing is on the way. Doing this from
  /// build, rather than once at the start, means a connection swapped mid-load can't
  /// leave the section waiting for an answer that was thrown away.
  void _askIfNeeded(ReportsController reports) {
    final isNeeded =
        reports.isAvailable &&
        !reports.isWantedLoaded &&
        !reports.isWantedLoading &&
        reports.wantedError == null;
    if (!isNeeded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reports.refreshWanted();
    });
  }

  Future<void> _export(List<WantedSong> wanted) async {
    final everyone = wanted;
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
        ClipboardData(text: exportWanted(everyone, WantedFormat.text).content),
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Copied ${everyone.length} songs')),
      );
      return;
    }
    final file = exportWanted(everyone, format.format!);
    await (widget.shareFile ?? shareExportedFile)(context, file);
  }

  @override
  Widget build(BuildContext context) {
    final reports = context.watch<ReportsController>();
    _askIfNeeded(reports);
    final library = context.watch<CatalogController>().songs;
    if (reports.isWantedLoaded && library.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) reports.closeWantedFoundIn(library);
      });
    }
    final wanted = reports.wanted;
    // What gets exported: everyone's wants plus any only this device has so far.
    final everyone = mergeWanted(
      wanted,
      missingFromImports(context.watch<ImportsController>().playlists),
    );
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
              if (everyone.isNotEmpty)
                IconButton(
                  tooltip: 'Export list',
                  icon: const Icon(Icons.ios_share_rounded),
                  onPressed: () => _export(everyone),
                ),
            ],
          ),
        ),
        _status(reports, wanted.length),
        for (final song in shown)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: kPagePadding,
            ),
            leading: CoverArt(
              coverArtId: null,
              size: 48,
              artist: song.artist,
              title: song.title,
              album: '',
              seed: song.title,
            ),
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

  /// The line under the title: what the list is, or why there isn't one.
  Widget _status(ReportsController reports, int count) {
    final style = yomiText(13, color: YomiColors.textSecondary);
    const padding = EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 4);
    if (!reports.isAvailable) {
      return Padding(
        padding: padding,
        child: Text(
          "The shared list isn't available on this connection.",
          style: style,
        ),
      );
    }
    if (reports.wantedError != null && !reports.isWantedLoaded) {
      return Padding(
        padding: padding,
        child: Row(
          children: [
            Expanded(
              child: Text(
                "Couldn't load the list. ${reports.wantedError}",
                style: style,
              ),
            ),
            TextButton(
              onPressed: reports.refreshWanted,
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (!reports.isWantedLoaded) {
      return Padding(
        padding: padding,
        child: Text('Loading…', style: style),
      );
    }
    if (count == 0) {
      return Padding(
        padding: padding,
        child: Text('Nobody has asked for a song yet.', style: style),
      );
    }
    return Padding(
      padding: padding,
      child: Text(
        "$count songs people have asked for that aren't in the library yet. "
        'Upload one and it drops off this list.',
        style: style,
      ),
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
