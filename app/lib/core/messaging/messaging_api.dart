import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../subsonic_client.dart';

const Duration _timeout = Duration(seconds: 15);

/// Longer than the server waits before answering that nothing has happened.
const Duration _eventsTimeout = Duration(seconds: 40);

@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.from,
    required this.to,
    required this.text,
    required this.sentAt,
    this.songId,
    this.songTitle,
    this.albumId,
    this.playlistId,
    this.replyTo,
    this.reactions = const {},
    this.isPending = false,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: (json['id'] as num).toInt(),
    from: json['from'] as String,
    to: json['to'] as String,
    text: (json['text'] as String?) ?? '',
    sentAt: DateTime.fromMillisecondsSinceEpoch(
      (json['sentMs'] as num).toInt(),
    ),
    songId: json['songId'] as String?,
    songTitle: json['songTitle'] as String?,
    albumId: json['albumId'] as String?,
    playlistId: json['playlistId'] as String?,
    replyTo: (json['replyTo'] as num?)?.toInt(),
    reactions: {
      for (final entry
          in ((json['reactions'] as Map<String, dynamic>?) ?? const {}).entries)
        entry.key: entry.value as String,
    },
    isPending: json['pending'] == true,
  );

  final int id;
  final String from;
  final String to;
  final String text;
  final DateTime sentAt;
  final String? songId;
  final String? songTitle;
  final String? albumId;
  final String? playlistId;
  final int? replyTo;

  /// Who reacted, and with what.
  final Map<String, String> reactions;

  /// Written here and still on its way to the server.
  final bool isPending;

  bool get isShare => songId != null || albumId != null || playlistId != null;

  Map<String, Object?> toJson() => {
    'id': id,
    'from': from,
    'to': to,
    'text': text,
    'sentMs': sentAt.millisecondsSinceEpoch,
    'songId': songId,
    'songTitle': songTitle,
    'albumId': albumId,
    'playlistId': playlistId,
    'replyTo': replyTo,
    'reactions': reactions,
    'pending': isPending,
  };
}

/// What someone who chose to share is listening to.
@immutable
class FriendPlaying {
  const FriendPlaying({required this.songId, this.title, this.artist});

  factory FriendPlaying.fromJson(Map<String, dynamic> json) => FriendPlaying(
    songId: json['songId'] as String,
    title: json['title'] as String?,
    artist: json['artist'] as String?,
  );

  final String songId;
  final String? title;
  final String? artist;
}

@immutable
class ChatProfile {
  const ChatProfile({
    required this.user,
    this.displayName = '',
    this.bio = '',
    this.hasAvatar = false,
    this.avatarVersion = 0,
    this.hasBanner = false,
    this.bannerVersion = 0,
    this.nowPlaying,
    this.taste,
  });

  factory ChatProfile.fromJson(Map<String, dynamic> json) => ChatProfile(
    user: json['user'] as String,
    displayName: (json['displayName'] as String?) ?? '',
    bio: (json['bio'] as String?) ?? '',
    hasAvatar: json['hasAvatar'] == true,
    avatarVersion: (json['avatarVersion'] as num?)?.toInt() ?? 0,
    hasBanner: json['hasBanner'] == true,
    bannerVersion: (json['bannerVersion'] as num?)?.toInt() ?? 0,
    nowPlaying: json['nowPlaying'] == null
        ? null
        : FriendPlaying.fromJson(json['nowPlaying'] as Map<String, dynamic>),
    taste: json['taste'] == null
        ? null
        : SharedTaste.fromJson(json['taste'] as Map<String, dynamic>),
  );

  final String user;
  final String displayName;
  final String bio;
  final bool hasAvatar;

  /// Changes whenever their picture does. Part of the picture's address, so a
  /// cached copy of the old one is never shown.
  final int avatarVersion;
  final bool hasBanner;
  final int bannerVersion;
  final FriendPlaying? nowPlaying;

  /// Their top artists and moods, if they share them.
  final SharedTaste? taste;

  String get name => displayName.isEmpty ? user : displayName;
}

/// What someone shares about their listening: a few names, never individual plays.
@immutable
class SharedTaste {
  const SharedTaste({this.topArtists = const [], this.topMoods = const []});

  factory SharedTaste.fromJson(Map<String, dynamic> json) => SharedTaste(
    topArtists: List.unmodifiable(
      (json['topArtists'] as List<dynamic>? ?? const []).whereType<String>(),
    ),
    topMoods: List.unmodifiable(
      (json['topMoods'] as List<dynamic>? ?? const []).whereType<String>(),
    ),
  );

  final List<String> topArtists;
  final List<String> topMoods;
}

@immutable
class ChatConversation {
  const ChatConversation({
    required this.withUser,
    required this.last,
    required this.unread,
  });

  factory ChatConversation.fromJson(Map<String, dynamic> json) =>
      ChatConversation(
        withUser: json['with'] as String,
        last: ChatMessage.fromJson(json['last'] as Map<String, dynamic>),
        unread: (json['unread'] as num?)?.toInt() ?? 0,
      );

  final String withUser;
  final ChatMessage last;
  final int unread;
}

/// The server has no messaging: too old, or a backup server.
class MessagingUnavailable implements Exception {
  const MessagingUnavailable();
}

/// A request failed for a reason worth showing to the user.
class MessagingException implements Exception {
  const MessagingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The server couldn't be reached, so a message can wait and try again later.
class MessagingOffline extends MessagingException {
  const MessagingOffline(super.message);
}

/// What the controller needs from the server. A separate type so it can be faked.
abstract interface class MessagingTransport {
  Future<List<ChatConversation>> conversations();
  Future<List<ChatMessage>> thread(
    String withUser, {
    int after = 0,
    int before = 0,
  });
  Future<ChatMessage> send(
    String to, {
    String text = '',
    String? songId,
    String? songTitle,
    String? albumId,
    String? playlistId,
    int? replyTo,
  });
  Future<void> react(int messageId, String emoji);

  /// Waits until something new concerns this user, then returns the revision to pass next
  /// time. Returns sooner if nothing happened for a while.
  Future<int> waitForChange(int revision);
  Future<void> setPlaying({String? songId, String? title, String? artist});
  Future<void> markRead(String withUser, int upTo);
  Future<List<ChatProfile>> profiles();
  Future<void> saveProfile({required String displayName, required String bio});

  /// Shares your top artists and moods with friends. Empty lists stop sharing.
  Future<void> saveTaste({
    required List<String> topArtists,
    required List<String> topMoods,
  });
  Future<void> saveAvatar(File image);
  Future<void> saveBanner(File image);

  /// Where a person's picture lives. [version] makes the address change with the
  /// picture, so image caches fetch the new one.
  Uri avatarUri(String user, {int version = 0});
  Uri bannerUri(String user, {int version = 0});

  /// The bytes at [uri], or null when there is nothing there.
  Future<List<int>?> fetchImage(Uri uri);
}

class MessagingApi implements MessagingTransport {
  MessagingApi({
    required this.serverUrl,
    required this.auth,
    required this.port,
  });

  final String serverUrl;
  final SubsonicClient auth;
  final int port;

  Uri _uri(String path, [Map<String, String> extra = const {}]) =>
      Uri.parse(serverUrl.replaceAll(RegExp(r'/+$'), '')).replace(
        port: port,
        path: path,
        // Stable, so repeated requests use the server's recent-login cache.
        queryParameters: {...auth.authParams(stable: true), ...extra},
      );

  Future<Map<String, dynamic>> _call(
    String method,
    Uri uri, {
    Object? body,
    List<int>? bytes,
    Duration timeout = _timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.openUrl(method, uri).timeout(_timeout);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      } else if (bytes != null) {
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return _decode(response.statusCode, text);
    } on SocketException {
      throw const MessagingOffline("Can't reach the server.");
    } on TimeoutException {
      throw const MessagingOffline("The server didn't answer in time.");
    } on HttpException {
      throw const MessagingOffline('The connection was interrupted.');
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, dynamic> _decode(int status, String text) {
    if (status == HttpStatus.notFound ||
        status == HttpStatus.serviceUnavailable) {
      // A person not found is reported with a reason; a missing route has none.
      final reason = _reasonIn(text);
      if (status == HttpStatus.notFound && reason != null) {
        throw MessagingException(reason);
      }
      throw const MessagingUnavailable();
    }
    if (status < 200 || status >= 300) {
      throw MessagingException(_reasonIn(text) ?? 'Request failed ($status).');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const MessagingException('The server sent something unexpected.');
    }
    return decoded;
  }

  static String? _reasonIn(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic>
          ? decoded['message'] as String?
          : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<List<ChatConversation>> conversations() async {
    final json = await _call('GET', _uri('/v1/conversations'));
    return List.unmodifiable(
      (json['conversations'] as List<dynamic>).cast<Map<String, dynamic>>().map(
        ChatConversation.fromJson,
      ),
    );
  }

  @override
  Future<List<ChatMessage>> thread(
    String withUser, {
    int after = 0,
    int before = 0,
  }) async {
    final json = await _call(
      'GET',
      _uri('/v1/messages', {
        'with': withUser,
        'after': '$after',
        if (before > 0) 'before': '$before',
      }),
    );
    return List.unmodifiable(
      (json['messages'] as List<dynamic>).cast<Map<String, dynamic>>().map(
        ChatMessage.fromJson,
      ),
    );
  }

  @override
  Future<void> react(int messageId, String emoji) async {
    await _call(
      'POST',
      _uri('/v1/messages/react'),
      body: {'id': messageId, 'emoji': emoji},
    );
  }

  @override
  Future<int> waitForChange(int revision) async {
    final json = await _call(
      'GET',
      _uri('/v1/events', {'rev': '$revision'}),
      timeout: _eventsTimeout,
    );
    return (json['rev'] as num).toInt();
  }

  @override
  Future<void> setPlaying({
    String? songId,
    String? title,
    String? artist,
  }) async {
    await _call(
      'PUT',
      _uri('/v1/profile/playing'),
      body: {'songId': songId ?? '', 'title': ?title, 'artist': ?artist},
    );
  }

  @override
  Future<ChatMessage> send(
    String to, {
    String text = '',
    String? songId,
    String? songTitle,
    String? albumId,
    String? playlistId,
    int? replyTo,
  }) async {
    final json = await _call(
      'POST',
      _uri('/v1/messages'),
      body: {
        'to': to,
        'text': text,
        'songId': ?songId,
        'songTitle': ?songTitle,
        'albumId': ?albumId,
        'playlistId': ?playlistId,
        'replyTo': ?replyTo,
      },
    );
    return ChatMessage.fromJson(json);
  }

  @override
  Future<void> markRead(String withUser, int upTo) => _call(
    'POST',
    _uri('/v1/messages/read'),
    body: {'with': withUser, 'upTo': upTo},
  );

  @override
  Future<List<ChatProfile>> profiles() async {
    final json = await _call('GET', _uri('/v1/profiles'));
    return List.unmodifiable(
      (json['profiles'] as List<dynamic>).cast<Map<String, dynamic>>().map(
        ChatProfile.fromJson,
      ),
    );
  }

  @override
  Future<void> saveProfile({
    required String displayName,
    required String bio,
  }) => _call(
    'PUT',
    _uri('/v1/profile'),
    body: {'displayName': displayName, 'bio': bio},
  );

  @override
  Future<void> saveTaste({
    required List<String> topArtists,
    required List<String> topMoods,
  }) => _call(
    'PUT',
    _uri('/v1/profile/taste'),
    body: {'topArtists': topArtists, 'topMoods': topMoods},
  );

  @override
  Future<void> saveAvatar(File image) async {
    await _call(
      'PUT',
      _uri('/v1/profile/avatar'),
      bytes: await image.readAsBytes(),
    );
  }

  @override
  Future<void> saveBanner(File image) async {
    await _call(
      'PUT',
      _uri('/v1/profile/banner'),
      bytes: await image.readAsBytes(),
    );
  }

  @override
  Uri avatarUri(String user, {int version = 0}) =>
      _uri('/v1/profiles/$user/avatar', {if (version > 0) 'v': '$version'});

  @override
  Uri bannerUri(String user, {int version = 0}) =>
      _uri('/v1/profiles/$user/banner', {if (version > 0) 'v': '$version'});

  @override
  Future<List<int>?> fetchImage(Uri uri) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode != HttpStatus.ok) {
        throw MessagingException(
          'Picture request failed (${response.statusCode}).',
        );
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add).timeout(_timeout);
      return builder.takeBytes();
    } on SocketException {
      throw const MessagingOffline("Can't reach the server.");
    } on TimeoutException {
      throw const MessagingOffline("The server didn't answer in time.");
    } on HttpException {
      throw const MessagingOffline('The connection was interrupted.');
    } finally {
      client.close(force: true);
    }
  }
}
