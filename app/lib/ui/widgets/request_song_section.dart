import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/song_database.dart';
import '../../core/spotify/spotify_export.dart';
import '../../core/spotify/track_matcher.dart';
import '../../state/catalog_controller.dart';
import '../../state/reports_controller.dart';
import '../theme.dart';
import 'report_sheet.dart';

class RequestSongSection extends StatefulWidget {
  const RequestSongSection({super.key, this.database});
  final SongDatabase? database;
  @override
  State<RequestSongSection> createState() => _RequestSongSectionState();
}

class _RequestSongSectionState extends State<RequestSongSection> {
  late final _database = widget.database ?? SongDatabase();
  final _query = TextEditingController();
  final _sent = <String>{};
  final _sending = <String>{};
  List<DatabaseSong> _songs = [];
  Timer? _timer;
  int _generation = 0;
  bool _loading = false, _searched = false;
  String? _error;
  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    if (widget.database == null) _database.close();
    super.dispose();
  }

  void _changed(String query) {
    _timer?.cancel();
    final generation = ++_generation;
    setState(() {
      _error = null;
      _songs = [];
      _searched = false;
      _loading = query.trim().length >= 2;
    });
    if (!_loading) return;
    _timer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final songs = await _database.search(query);
        if (!mounted || generation != _generation) return;
        setState(() {
          _songs = songs;
          _loading = false;
          _searched = true;
        });
      } on Object {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _error = 'Could not search the song database. Try again.';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final reports = context.watch<ReportsController?>();
    if (reports == null) return const SizedBox.shrink();
    final matcher = TrackMatcher(context.watch<CatalogController>().songs);
    return Padding(
      padding: const EdgeInsets.all(kPagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Request a song', style: yomiText(18, weight: FontWeight.w800)),
          const Text('Find the recording you want added to the library.'),
          const SizedBox(height: 12),
          TextField(
            controller: _query,
            onChanged: _changed,
            decoration: const InputDecoration(
              hintText: 'Song or artist',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            TextButton(
              onPressed: () => _changed(_query.text),
              child: Text(_error!),
            ),
          if (_searched && _songs.isEmpty)
            const Text('No recordings found. Try the artist and title.'),
          for (final song in _songs)
            Builder(
              builder: (context) {
                final key = '${song.artist}|${song.title}';
                final inLibrary =
                    matcher
                        .match(
                          ExportTrack(artist: song.artist, title: song.title),
                        )
                        .status ==
                    MatchStatus.matched;
                final sent = _sent.contains(key);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: SizedBox.square(
                    dimension: 48,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: song.cover == null
                          ? const Icon(Icons.music_note)
                          : Image.network(
                              song.cover!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.music_note),
                            ),
                    ),
                  ),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${song.artist} · ${song.album}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: TextButton(
                    onPressed:
                        !reports.isAvailable ||
                            inLibrary ||
                            sent ||
                            _sending.contains(key)
                        ? null
                        : () async {
                            setState(() => _sending.add(key));
                            final ok = await requestSong(
                              context,
                              artist: song.artist,
                              title: song.title,
                            );
                            if (!mounted) return;
                            setState(() {
                              _sending.remove(key);
                              if (ok) _sent.add(key);
                            });
                          },
                    child: Text(
                      inLibrary
                          ? 'In library'
                          : sent
                          ? 'Requested'
                          : _sending.contains(key)
                          ? 'Sending…'
                          : 'Request',
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
