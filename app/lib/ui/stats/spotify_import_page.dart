import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/listening/past_favourites.dart';
import '../../core/spotify/spotify_export.dart';
import '../../core/spotify/spotify_link.dart';
import '../../state/catalog_controller.dart';
import '../../state/listening_log.dart';
import '../imports/import_review_page.dart';
import '../theme.dart';
import 'stats_page.dart';
import '../widgets/youtube_play_button.dart';

/// Brings your Spotify years into Yomi from the files Spotify sends you.
class SpotifyImportPage extends StatefulWidget {
  const SpotifyImportPage({super.key});

  @override
  State<SpotifyImportPage> createState() => _SpotifyImportPageState();
}

class _SpotifyImportPageState extends State<SpotifyImportPage> {
  final _link = TextEditingController();
  bool _isWorking = false;
  String? _result;
  List<ExportPlaylist> _found = const [];

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _useLink() async {
    final navigator = Navigator.of(context);
    setState(() {
      _isWorking = true;
      _result = null;
    });
    try {
      final linked = await fetchSpotifyPlaylist(_link.text);
      if (!mounted) return;
      await navigator.push(
        yomiRoute<void>(
          builder: (_) => ImportReviewPage(
            playlist: linked.playlist,
            mayBeIncomplete: linked.mayBeIncomplete,
          ),
        ),
      );
    } on SpotifyLinkException catch (error) {
      if (mounted) setState(() => _result = error.message);
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  void _review(ExportPlaylist playlist) {
    Navigator.of(context).push(
      yomiRoute<void>(builder: (_) => ImportReviewPage(playlist: playlist)),
    );
  }

  Future<void> _pick() async {
    final log = context.read<ListeningLog>();
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _isWorking = true;
      _result = null;
    });
    try {
      var history = <HistoryRow>[];
      final liked = <ExportTrack>[];
      final playlists = <ExportPlaylist>[];
      for (final file in picked) {
        final path = file.path;
        if (path == null) continue;
        final name = file.name;
        final part = await Isolate.run(() => _readFile(name, path));
        history = [...history, ...part.history];
        liked.addAll(part.likedSongs);
        playlists.addAll(part.playlists);
      }
      if (!mounted) return;
      final added = await log.importSpotify(history);
      if (!mounted) return;
      setState(
        () => _result = _describe(
          totalRows: history.length,
          added: added,
          liked: liked.length,
          playlists: playlists.length,
        ),
      );
      setState(
        () => _found = [
          if (liked.isNotEmpty)
            ExportPlaylist(name: 'Liked Songs', tracks: liked),
          ...playlists.where((playlist) => playlist.tracks.isNotEmpty),
        ],
      );
    } on Object catch (error) {
      debugPrint('Could not import from Spotify: $error');
      if (mounted) {
        setState(() => _result = "Couldn't read those files. Nothing changed.");
      }
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  /// A real export is far smaller. Reading anything much bigger would run out of memory.
  static const int _maxFileBytes = 1 << 30;

  static SpotifyExport _readFile(String name, String path) {
    if (File(path).lengthSync() > _maxFileBytes) return const SpotifyExport();
    if (name.toLowerCase().endsWith('.csv')) {
      final title = name.substring(0, name.length - '.csv'.length);
      final playlist = parsePlaylistCsv(title, File(path).readAsStringSync());
      return SpotifyExport(
        playlists: [if (playlist.tracks.isNotEmpty) playlist],
      );
    }
    return readExport(name, File(path).readAsBytesSync());
  }

  String _describe({
    required int totalRows,
    required int added,
    required int liked,
    required int playlists,
  }) {
    if (totalRows == 0 && liked == 0 && playlists == 0) {
      return "That doesn't look like a Spotify export. Nothing changed.";
    }
    return [
      if (totalRows > 0)
        added == 0
            ? 'Your listening history was already here.'
            : 'Added ${formatCount(added)} listens to your stats.',
      if (playlists > 0) 'Found $playlists playlists.',
      if (liked > 0) 'Found ${formatCount(liked)} liked songs.',
    ].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            'Import from Spotify',
            style: yomiText(20, weight: FontWeight.w800),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(kPagePadding),
          children: [
            Text(
              'Choose your Spotify data export, or paste a public playlist link.',
              style: yomiText(
                14,
                weight: FontWeight.w500,
                color: YomiColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _isWorking ? null : _pick,
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(_isWorking ? 'Reading…' : 'Choose files'),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _link,
              decoration: const InputDecoration(
                hintText: 'https://open.spotify.com/playlist/…',
              ),
              onSubmitted: (_) => _useLink(),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _isWorking ? null : _useLink,
              child: const Text('Use this link'),
            ),
            if (result != null) ...[
              const SizedBox(height: 16),
              Text(result, style: yomiText(14, weight: FontWeight.w600)),
            ],
            if (_found.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                'Choose what to bring in',
                style: yomiText(15, weight: FontWeight.w700),
              ),
              for (final playlist in _found)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.tracks.length} songs'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _review(playlist),
                ),
            ],
            const _MissingFavourites(),
          ],
        ),
      ),
    );
  }
}

/// What you played most on Spotify that isn't in your library, to go and find.
class _MissingFavourites extends StatelessWidget {
  const _MissingFavourites();

  @override
  Widget build(BuildContext context) {
    final imported = context.watch<ListeningLog>().imported;
    final library = context.watch<CatalogController>().songs;
    final missing = missingFavourites(imported, library);
    if (missing.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          "Favourites you don't have yet",
          style: yomiText(15, weight: FontWeight.w700),
        ),
        for (final track in missing)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              track.track,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${track.artist} · ${formatCount(track.plays)} plays',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: YoutubePlayButton(
              artist: track.artist,
              title: track.track,
            ),
          ),
      ],
    );
  }
}
