import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../subsonic_client.dart';

const Duration _timeout = Duration(seconds: 15);

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
  );

  final int id;
  final String from;
  final String to;
  final String text;
  final DateTime sentAt;
  final String? songId;
  final String? songTitle;
}

@immutable
class ChatProfile {
  const ChatProfile({
    required this.user,
    this.displayName = '',
    this.bio = '',
    this.hasAvatar = false,
  });

  factory ChatProfile.fromJson(Map<String, dynamic> json) => ChatProfile(
    user: json['user'] as String,
    displayName: (json['displayName'] as String?) ?? '',
    bio: (json['bio'] as String?) ?? '',
    hasAvatar: json['hasAvatar'] == true,
  );

  final String user;
  final String displayName;
  final String bio;
  final bool hasAvatar;

  String get name => displayName.isEmpty ? user : displayName;
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

/// What the controller needs from the server. A separate type so it can be faked.
abstract interface class MessagingTransport {
  Future<List<ChatConversation>> conversations();
  Future<List<ChatMessage>> thread(String withUser, {int after = 0});
  Future<ChatMessage> send(
    String to, {
    String text = '',
    String? songId,
    String? songTitle,
  });
  Future<void> markRead(String withUser, int upTo);
  Future<List<ChatProfile>> profiles();
  Future<void> saveProfile({required String displayName, required String bio});
  Future<void> saveAvatar(File image);
  Uri avatarUri(String user);
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
        queryParameters: {...auth.authParams(), ...extra},
      );

  Future<Map<String, dynamic>> _call(
    String method,
    Uri uri, {
    Object? body,
    List<int>? bytes,
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
      final response = await request.close().timeout(_timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      return _decode(response.statusCode, text);
    } on SocketException {
      throw const MessagingException("Can't reach the server.");
    } on TimeoutException {
      throw const MessagingException("The server didn't answer in time.");
    } on HttpException {
      throw const MessagingException('The connection was interrupted.');
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
  Future<List<ChatMessage>> thread(String withUser, {int after = 0}) async {
    final json = await _call(
      'GET',
      _uri('/v1/messages', {'with': withUser, 'after': '$after'}),
    );
    return List.unmodifiable(
      (json['messages'] as List<dynamic>).cast<Map<String, dynamic>>().map(
        ChatMessage.fromJson,
      ),
    );
  }

  @override
  Future<ChatMessage> send(
    String to, {
    String text = '',
    String? songId,
    String? songTitle,
  }) async {
    final json = await _call(
      'POST',
      _uri('/v1/messages'),
      body: {
        'to': to,
        'text': text,
        'songId': ?songId,
        'songTitle': ?songTitle,
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
  Future<void> saveAvatar(File image) async {
    await _call(
      'PUT',
      _uri('/v1/profile/avatar'),
      bytes: await image.readAsBytes(),
    );
  }

  @override
  Uri avatarUri(String user) => _uri('/v1/profiles/$user/avatar');
}
