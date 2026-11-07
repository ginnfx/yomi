import 'dart:async';

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
  int _generation = 0;
  Future<void> _pending = Future.value();

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
    if (_isRestoring ||
        (!profile.hasContent &&
            !profile.avatarRemovalPending &&
            !profile.bannerRemovalPending))
      return;
    final generation = _generation;
    _pending = _pending.then((_) => _send(generation)).catchError((
      Object error,
    ) {
      // Keep pending edits for the next connection or profile change.
    });
  }

  Future<void> _send(int generation) async {
    if (generation != _generation) return;
    final avatarFile = profile.avatarFile;
    final bannerFile = profile.bannerFile;
    final avatar = avatarFile?.path != _publishedAvatar ? avatarFile : null;
    final banner = bannerFile?.path != _publishedBanner ? bannerFile : null;
    final removeAvatar = profile.avatarRemovalPending;
    final removeBanner = profile.bannerRemovalPending;
    final isDone = await messages.publishProfile(
      displayName: profile.nickname,
      bio: profile.bio,
      avatar: avatar,
      banner: banner,
      removeAvatar: removeAvatar,
      removeBanner: removeBanner,
    );
    // A failed upload is tried again with the next edit.
    if (!isDone || generation != _generation) return;
    await profile.acknowledgeImageRemovals(
      avatar: removeAvatar,
      banner: removeBanner,
    );
    if (avatar != null) _publishedAvatar = avatar.path;
    if (banner != null) _publishedBanner = banner.path;
  }

  void _restoreOnce() {
    if (!_needsRestore || messages.people.isEmpty) return;
    _needsRestore = false;
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final generation = _generation;
    final mine = messages.profileOf(username());
    _isRestoring = true;
    try {
      if (generation != _generation || profile.hasContent) return;
      if (mine.displayName.isNotEmpty) {
        await profile.setNickname(mine.displayName);
      }
      if (generation != _generation) return;
      if (mine.bio.isNotEmpty) await profile.setBio(mine.bio);
      if (generation != _generation) return;
      if (mine.hasAvatar && !profile.avatarRemovalPending) {
        final bytes = await messages.fetchPersonImage(mine, isBanner: false);
        if (generation != _generation) return;
        if (bytes != null && profile.avatarFile == null) {
          await profile.restoreAvatar(bytes);
          _publishedAvatar = profile.avatarFile?.path;
        }
      }
      if (generation != _generation) return;
      if (mine.hasBanner && !profile.bannerRemovalPending) {
        final bytes = await messages.fetchPersonImage(mine, isBanner: true);
        if (generation != _generation) return;
        if (bytes != null && profile.bannerFile == null) {
          await profile.restoreBanner(bytes);
          _publishedBanner = profile.bannerFile?.path;
        }
      }
    } finally {
      if (generation == _generation) _isRestoring = false;
    }
  }

  /// Forgets what was uploaded, for the next person to sign in.
  void reset() {
    _generation++;
    _isRestoring = false;
    _needsRestore = true;
    _publishedAvatar = null;
    _publishedBanner = null;
  }
}
