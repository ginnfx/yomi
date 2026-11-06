import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/reports/reports_api.dart';
import '../../state/reports_controller.dart';
import '../theme.dart';

/// Problems a person can report about a song they're looking at.
const List<ReportKind> kSongProblemKinds = [
  ReportKind.explicitWanted,
  ReportKind.coverMissing,
  ReportKind.coverWrong,
  ReportKind.other,
];

/// Asks what's wrong with [song] and sends it to the server's "needs fixing" list.
Future<void> showReportSheet(
  BuildContext context,
  Song song, {
  ReportKind? preselected,
}) {
  final reports = context.read<ReportsController>();
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: reports,
      child: _ReportSheet(
        song: song,
        preselected:
            preselected ?? (song.isClean ? ReportKind.explicitWanted : null),
        onSent: (isSent) => messenger.showSnackBar(
          SnackBar(
            content: Text(
              isSent
                  ? 'Thanks. It is on the list of things to fix.'
                  : reports.error ?? 'Could not send the report.',
            ),
          ),
        ),
      ),
    ),
  );
}

/// Asks to add a song that isn't in the library.
Future<bool> requestSong(
  BuildContext context, {
  required String artist,
  required String title,
}) async {
  final reports = context.read<ReportsController>();
  final messenger = ScaffoldMessenger.of(context);
  final isSent = await reports.report(
    ReportInput(kind: ReportKind.missingSong, artist: artist, title: title),
  );
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        isSent
            ? 'Requested "$title"'
            : reports.error ?? 'Could not request it.',
      ),
    ),
  );
  return isSent;
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({
    required this.song,
    required this.preselected,
    required this.onSent,
  });

  final Song song;
  final ReportKind? preselected;
  final ValueChanged<bool> onSent;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  late ReportKind? _kind = widget.preselected;
  final _note = TextEditingController();
  bool _isSending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final kind = _kind;
    if (kind == null || _isSending) return;
    setState(() => _isSending = true);
    final navigator = Navigator.of(context);
    final isSent = await context.read<ReportsController>().report(
      ReportInput.forSong(widget.song, kind, note: _note.text),
    );
    if (!mounted) return;
    setState(() => _isSending = false);
    if (isSent) navigator.pop();
    widget.onSent(isSent);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        kPagePadding,
        0,
        kPagePadding,
        kPagePadding + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Report a problem',
            style: yomiText(20, weight: FontWeight.w800),
          ),
          Text(
            '${widget.song.title} · ${widget.song.artist}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: yomiText(13, color: YomiColors.textSecondary),
          ),
          const SizedBox(height: YomiSpace.s),
          RadioGroup<ReportKind>(
            groupValue: _kind,
            onChanged: (kind) => setState(() => _kind = kind),
            child: Column(
              children: [
                for (final kind in kSongProblemKinds)
                  RadioListTile<ReportKind>(
                    contentPadding: EdgeInsets.zero,
                    value: kind,
                    title: Text(kind.label),
                  ),
              ],
            ),
          ),
          TextField(
            controller: _note,
            maxLength: 300,
            decoration: const InputDecoration(
              hintText: 'Anything that helps (optional)',
            ),
          ),
          const SizedBox(height: YomiSpace.s),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _kind == null || _isSending ? null : _send,
              child: Text(_isSending ? 'Sending…' : 'Send'),
            ),
          ),
        ],
      ),
    ),
  );
}
