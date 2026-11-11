import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';

Future<void> showVolumeBoost(BuildContext context, Song song) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _VolumeBoost(
        song: song,
        player: context.read<PlayerController>(),
        session: context.read<SessionController>(),
      ),
    );

class _VolumeBoost extends StatefulWidget {
  const _VolumeBoost({
    required this.song,
    required this.player,
    required this.session,
  });
  final Song song;
  final PlayerController player;
  final SessionController session;
  @override
  State<_VolumeBoost> createState() => _VolumeBoostState();
}

class _VolumeBoostState extends State<_VolumeBoost> {
  bool _busy = false;
  String? _error;
  final _client = http.Client();
  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _set(int db) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    File? file;
    try {
      if (db != 0) {
        final session = widget.session;
        final client = session.client;
        final uri = Uri.parse(session.serverUrl).replace(
          port: session.uploadServicePort,
          pathSegments: ['v1', 'audio', 'boost', widget.song.id],
          queryParameters: {...session.client.authParams(), 'gain': '$db'},
        );
        final response = await _client
            .get(uri)
            .timeout(const Duration(minutes: 2));
        if (response.statusCode != 200 ||
            !(response.headers['content-type'] ?? '').startsWith('audio/')) {
          throw const HttpException(
            'Could not boost this song. The server needs volume boost support and ffmpeg.',
          );
        }
        if (!mounted) return;
        if (!identical(client, session.client))
          throw StateError('Connection changed');
        final dir = await Directory.systemTemp.createTemp('yomi-boost-');
        file = await File('${dir.path}/audio.mp3')
            .writeAsBytes(response.bodyBytes);
      }
      await widget.player.useBoost(widget.song, file, db);
      if (mounted) Navigator.pop(context);
    } on Object {
      if (file != null && await file.exists()) await file.delete();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not prepare boost. Check the connection and server ffmpeg support.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Volume boost', style: Theme.of(context).textTheme.titleLarge),
          const Text(
            'For quiet recordings. Applies to this song for this session. Preparing a boosted copy needs a connection. Peaks are limited to reduce clipping.',
          ),
          for (final db in [0, 3, 6])
            ListTile(
              title: Text(db == 0 ? 'Off' : '+$db dB'),
              trailing: widget.player.boostFor(widget.song) == db
                  ? const Icon(Icons.check)
                  : null,
              onTap: _busy ? null : () => _set(db),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
  );
}
