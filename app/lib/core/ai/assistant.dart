import 'package:flutter/foundation.dart';

import '../models.dart';
import '../search_index.dart';

/// One turn of a conversation with the assistant. Kept on this device only.
@immutable
class ChatTurn {
  const ChatTurn.user(this.text) : isUser = true, answer = null;
  const ChatTurn.assistant(ChatAnswer this.answer) : isUser = false, text = '';

  final bool isUser;
  final String text;
  final ChatAnswer? answer;

  Map<String, String> toJson() => {
    'role': isUser ? 'user' : 'assistant',
    'text': isUser ? text : answer!.forHistory,
  };
}

/// A song the AI named; [song] is the library copy when there is one.
@immutable
class SuggestedSong {
  const SuggestedSong({
    required this.artist,
    required this.title,
    this.reason = '',
    this.song,
  });

  factory SuggestedSong.fromJson(Map<String, dynamic> json) => SuggestedSong(
    artist: (json['artist'] as String?)?.trim() ?? '',
    title: (json['title'] as String?)?.trim() ?? '',
    reason: (json['reason'] as String?)?.trim() ?? '',
  );

  final String artist;
  final String title;
  final String reason;
  final Song? song;

  bool get isInLibrary => song != null;

  SuggestedSong withSong(Song? match) =>
      SuggestedSong(artist: artist, title: title, reason: reason, song: match);
}

/// What the assistant answered.
@immutable
class ChatAnswer {
  const ChatAnswer({
    required this.reply,
    this.songs = const [],
    this.playlistName,
  });

  factory ChatAnswer.fromJson(Map<String, dynamic> json) => ChatAnswer(
    reply: (json['reply'] as String?)?.trim() ?? '',
    songs: [
      for (final item
          in (json['songs'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>())
        SuggestedSong.fromJson(item),
    ],
    playlistName: switch (json['playlistName']) {
      final String name when name.trim().isNotEmpty => name.trim(),
      _ => null,
    },
  );

  final String reply;
  final List<SuggestedSong> songs;
  final String? playlistName;

  List<Song> get librarySongs => [
    for (final suggestion in songs)
      if (suggestion.song case final song?) song,
  ];

  List<SuggestedSong> get missing => [
    for (final suggestion in songs)
      if (!suggestion.isInLibrary) suggestion,
  ];

  /// How this answer is retold to the assistant on the next question.
  String get forHistory => [
    reply,
    for (final song in songs) '${song.artist} - ${song.title}',
  ].join('\n');

  ChatAnswer matchedWith(SearchIndex index) => ChatAnswer(
    reply: reply,
    songs: [
      for (final song in songs) song.withSong(findInLibrary(song, index)),
    ],
    playlistName: playlistName,
  );
}

/// The library song the AI meant: same title, and the artist named in the song's.
Song? findInLibrary(SuggestedSong suggestion, SearchIndex index) {
  final title = normalizeForSearch(suggestion.title);
  final artist = normalizeForSearch(suggestion.artist);
  if (title.isEmpty) return null;
  for (final song
      in index.search('${suggestion.artist} ${suggestion.title}').songs) {
    final songTitle = normalizeForSearch(song.title);
    final songArtist = normalizeForSearch(song.artist);
    final isSameTitle = songTitle == title || songTitle.startsWith('$title ');
    final isSameArtist =
        artist.isEmpty ||
        songArtist.contains(artist) ||
        (songArtist.isNotEmpty && artist.contains(songArtist));
    if (isSameTitle && isSameArtist) return song;
  }
  return null;
}
