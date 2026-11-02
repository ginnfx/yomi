import 'dart:async';
import 'dart:io';

import 'subsonic_client.dart';

enum ErrorAction { retry, openSettings, none }

/// What the user sees when something fails: a short title, one helpful sentence, and a next step.
class FriendlyError {
  const FriendlyError(this.title, this.hint, {this.action = ErrorAction.retry});

  final String title;
  final String hint;
  final ErrorAction action;
}

/// Explains a failure in plain words, using what we know about where the user is.
FriendlyError explainError(
  Object error, {
  required bool isOffline,
  required bool isAtHomeRoute,
  required bool hasHomeAddress,
  required bool isOnWifi,
}) {
  if (isOffline) {
    return const FriendlyError(
      "You're offline",
      'Songs you downloaded still play. The rest needs a connection.',
      action: ErrorAction.none,
    );
  }
  final kind = error is SubsonicException ? error.kind : _kindOf(error);
  switch (kind) {
    case ErrorKind.badCredentials:
      return const FriendlyError(
        'Wrong username or password',
        'Check your login in Settings, or sign in again.',
        action: ErrorAction.openSettings,
      );
    case ErrorKind.notNavidrome:
      return const FriendlyError(
        "That isn't your music server",
        'The address answered, but not with Navidrome. Check the address and port in Settings.',
        action: ErrorAction.openSettings,
      );
    case ErrorKind.server:
      return const FriendlyError(
        'The server had a problem',
        'It is running but could not do that. Try again in a moment.',
      );
    case ErrorKind.unreachable:
      if (isAtHomeRoute) {
        return const FriendlyError(
          "Can't reach your home server",
          'Is the server phone powered on and connected to your Wi-Fi?',
        );
      }
      if (!isOnWifi) {
        return const FriendlyError(
          "Can't reach your server",
          'Away from home? Make sure Tailscale is switched on, then try again.',
        );
      }
      return FriendlyError(
        "Can't reach your server",
        hasHomeAddress
            ? "You're on Wi-Fi but not at home. Make sure Tailscale is on, or check the addresses in Settings."
            : 'Check the server address in Settings and that the server is on.',
        action: ErrorAction.openSettings,
      );
    case ErrorKind.other:
      return FriendlyError('Something went wrong', '$error');
  }
}

ErrorKind _kindOf(Object error) {
  if (error is SocketException ||
      error is TimeoutException ||
      error is HttpException)
    return ErrorKind.unreachable;
  return ErrorKind.other;
}
