import 'dart:async';
import 'dart:io' show File;

import 'messages_controller.dart';
import 'profile_controller.dart';

/// Keeps this person's profile the same on the server and on this device:
/// publishes edits, and after a reinstall or new sign-in takes the name, bio,
/// picture and banner back from the server.
class ProfileSync {
  ProfileSync({
    required this.profile,
    required this.messages,
    required this.username,
  });

  final ProfileController profile;
  final MessagesController messages;
  final String Function() username;

  late bool _needsRestore = !profile.hasContent;
  String? _publishedAvatar;
  String? _publishedBanner;
  bool _isRestoring = false;

  void start() {
    messages.addListener(_restoreOnce);
    profile.addListener(publish);
  }

  void dispose() {
    messages.removeListener(_restoreOnce);
    profile.removeListener(publish);
  }

  /// Pictures are only uploaded when they changed, not on every edit of the bio.
  void publish() {
    if (_isRestoring || !profile.hasContent) return;
    final avatar = profile.avatarFile;
    final banner = profile.bannerFile;
    final avatarChanged = avatar != null && avatar.path != _publishedAvatar;
    final bannerChanged = banner != null && banner.path != _publishedBanner;
    unawaited(
      _send(avatarChanged ? avatar : null, bannerChanged ? banner : null),
    );
  }

  Future<void> _send(File? avatar, File? banner) async {
    final isDone = await messages.publishProfile(
      displayName: profile.nickname,
      bio: profile.bio,
      avatar: avatar,
      banner: banner,
    );
    // A failed upload is tried again with the next edit.
    if (!isDone) return;
    if (avatar != null) _publishedAvatar = avatar.path;
    if (banner != null) _publishedBanner = banner.path;
  }

  void _restoreOnce() {
    if (!_needsRestore || messages.people.isEmpty) return;
    _needsRestore = false;
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final mine = messages.profileOf(username());
    _isRestoring = true;
    try {
      if (profile.hasContent) return;
      if (mine.displayName.isNotEmpty) {
        await profile.setNickname(mine.displayName);
      }
      if (mine.bio.isNotEmpty) await profile.setBio(mine.bio);
      if (mine.hasAvatar) {
        final bytes = await messages.fetchPersonImage(mine, isBanner: false);
        if (bytes != null && profile.avatarFile == null) {
          await profile.restoreAvatar(bytes);
          _publishedAvatar = profile.avatarFile?.path;
        }
      }
      if (mine.hasBanner) {
        final bytes = await messages.fetchPersonImage(mine, isBanner: true);
        if (bytes != null && profile.bannerFile == null) {
          await profile.restoreBanner(bytes);
          _publishedBanner = profile.bannerFile?.path;
        }
      }
    } finally {
      _isRestoring = false;
    }
  }

  /// Forgets what was uploaded, for the next person to sign in.
  void reset() {
    _needsRestore = true;
    _publishedAvatar = null;
    _publishedBanner = null;
  }
}
