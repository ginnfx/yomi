import 'package:flutter/material.dart';

import '../../core/app_update.dart';
import '../../core/release_notes.dart';
import '../theme.dart';

/// Shows what a release changed: a sheet on phones, a window on a wide screen.
Future<void> showReleaseNotes(
  BuildContext context,
  ReleaseInfo release, {
  bool isInstalled = false,
}) {
  final title = isInstalled
      ? 'Updated to Yomi ${release.version}'
      : "What's new in Yomi ${release.version}";
  final body = _NotesBody(title: title, notes: release.notes);
  if (context.isWideLayout) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
          child: body,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: body,
      ),
    ),
  );
}

class _NotesBody extends StatelessWidget {
  const _NotesBody({required this.title, required this.notes});

  final String title;
  final String notes;

  @override
  Widget build(BuildContext context) {
    final lines = releaseNoteLines(notes);
    return Padding(
      padding: const EdgeInsets.all(YomiSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: yomiText(19, weight: FontWeight.w800)),
          const SizedBox(height: YomiSpace.m),
          Flexible(
            child: lines.isEmpty
                ? Text(
                    'This update has no release notes.',
                    style: yomiText(14, color: YomiColors.textSecondary),
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in lines)
                          line.isEmpty
                              ? const SizedBox(height: YomiSpace.s)
                              : Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    line,
                                    style: yomiText(
                                      14,
                                      weight: FontWeight.w500,
                                      height: 1.35,
                                      color: line.startsWith('• ')
                                          ? YomiColors.textPrimary
                                          : YomiColors.textSecondary,
                                    ),
                                  ),
                                ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
