import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../theme.dart';
import '../widgets/downloaded_songs.dart';
import 'settings_page.dart';

/// Shown when the server can't be reached: your downloaded songs, nothing else.
class OfflinePage extends StatefulWidget {
  const OfflinePage({super.key});

  @override
  State<OfflinePage> createState() => _OfflinePageState();
}

class _OfflinePageState extends State<OfflinePage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final isChecking = context.select<SessionController, bool>(
      (s) => s.isChecking,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Offline',
                  style: yomiText(30, weight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => openSettings(context),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: YomiColors.surfaceHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  size: 18,
                  color: YomiColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "Can't reach your server",
                    style: yomiText(
                      13.5,
                      weight: FontWeight.w600,
                      color: YomiColors.textSecondary,
                    ),
                  ),
                ),
                if (isChecking)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(
                    onPressed: () =>
                        context.read<SessionController>().checkServer(),
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 12, kPagePadding, 6),
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: InputDecoration(
              hintText: 'Search downloaded',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              filled: true,
              fillColor: YomiColors.surfaceHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(child: DownloadedSongs(query: _query)),
      ],
    );
  }
}
