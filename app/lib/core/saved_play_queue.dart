import 'models.dart';

/// A user's listening position, held by Navidrome rather than by one device.
class SavedPlayQueue {
  const SavedPlayQueue({
    required this.songs,
    required this.index,
    required this.position,
    this.changed,
    this.changedBy = '',
  });

  static SavedPlayQueue? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final songs = jsonList(
      json,
      'entry',
    ).map(Song.fromJson).toList(growable: false);
    if (songs.isEmpty) return null;
    final current = json['current']?.toString();
    final found = songs.indexWhere((s) => s.id == current);
    final index = found < 0 ? 0 : found;
    final raw = (json['position'] as num?)?.toInt() ?? 0;
    final duration = songs[index].duration.inMilliseconds;
    return SavedPlayQueue(
      songs: List.unmodifiable(songs),
      index: index,
      position: Duration(
        milliseconds: raw.clamp(0, duration > 0 ? duration : raw.abs()),
      ),
      changed: DateTime.tryParse(json['changed']?.toString() ?? ''),
      changedBy: json['changedBy']?.toString() ?? '',
    );
  }

  final List<Song> songs;
  final int index;
  final Duration position;
  final DateTime? changed;
  final String changedBy;
  Song get current => songs[index];

  String get deviceLabel {
    final client = changedBy.toLowerCase();
    if (client.startsWith('yomi/macos/')) return 'Mac';
    if (client.startsWith('yomi/ios/')) return 'iPhone';
    if (client.startsWith('yomi/android/')) return 'Android';
    return 'another device';
  }

  String get revision =>
      '${changed?.toIso8601String()}|$changedBy|${current.id}|${position.inMilliseconds}|${songs.map((s) => s.id).join(',')}';
}
