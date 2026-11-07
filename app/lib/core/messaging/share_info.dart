import '../models.dart';
import '../subsonic_client.dart';
import 'messaging_api.dart';

enum ShareKind { song, album, playlist }

/// What a shared song, album or playlist looks like in a conversation.
class ShareInfo {
  const ShareInfo({
    required this.kind,
    required this.title,
    required this.subtitle,
    this.coverArtId,
  });

  final ShareKind kind;
  final String title;
  final String subtitle;
  final String? coverArtId;
}

ShareKind? shareKindOf(ChatMessage message) {
  if (message.songId != null) return ShareKind.song;
  if (message.albumId != null) return ShareKind.album;
  if (message.playlistId != null) return ShareKind.playlist;
  return null;
}

/// Looks up the cover, title and artist behind a share, using what's already
/// saved before asking the server. Returns null if it can't be found, in which
/// case the message's own title is shown.
Future<ShareInfo?> loadShareInfo(
  ChatMessage message,
  SubsonicClient client, {
  List<Song> library = const [],
}) async {
  final kind = shareKindOf(message);
  if (kind == null) return null;
  try {
    switch (kind) {
      case ShareKind.song:
        final id = message.songId!;
        final song =
            library.where((s) => s.id == id).firstOrNull ??
            await client.song(id);
        return ShareInfo(
          kind: kind,
          title: song.title,
          subtitle: song.artist,
          coverArtId: song.coverArtId,
        );
      case ShareKind.album:
        final id = message.albumId!;
        final songs =
            client.cachedAlbumSongs(id) ?? await client.albumSongs(id);
        final first = songs.firstOrNull;
        return ShareInfo(
          kind: kind,
          title: message.songTitle ?? first?.album ?? 'Album',
          subtitle: first == null ? 'Album' : 'Album · ${first.artist}',
          coverArtId: first?.coverArtId,
        );
      case ShareKind.playlist:
        final id = message.playlistId!;
        final playlists = client.cachedPlaylists ?? await client.playlists();
        final playlist = playlists.where((p) => p.id == id).firstOrNull;
        if (playlist == null) return null;
        return ShareInfo(
          kind: kind,
          title: playlist.name,
          subtitle: 'Playlist · ${playlist.songCount} songs',
          coverArtId: playlist.coverArtId,
        );
    }
  } on Object {
    return null;
  }
}
