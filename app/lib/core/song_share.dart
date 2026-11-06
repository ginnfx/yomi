import 'models.dart';

/// Where anyone can listen to a song, Yomi account or not. Yomi's own server is private
/// (reached over Tailscale), so a link into it would only work for people already on it.
Uri songListenLink(Song song) => Uri.https('music.youtube.com', '/search', {
  'q': '${song.title} ${song.artist}',
});

/// The message that goes with a shared song, for WhatsApp, Messages and the like.
String songShareText(Song song) =>
    '${song.title} · ${song.artist}\n${songListenLink(song)}';
