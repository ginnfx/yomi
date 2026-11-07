import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/state/messages_controller.dart';
import 'package:yomi/state/profile_controller.dart';
import 'package:yomi/state/profile_sync.dart';

class _Messages extends MessagesController {
  bool succeeds = false;
  final removals = <(bool, bool)>[];

  @override
  Future<bool> publishProfile({
    required String displayName,
    required String bio,
    File? avatar,
    File? banner,
    bool removeAvatar = false,
    bool removeBanner = false,
  }) async {
    removals.add((removeAvatar, removeBanner));
    return succeeds;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('image removal survives a failed publish and restart', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('profile_removal');
    addTearDown(() => dir.delete(recursive: true));
    final profile = await ProfileController.load(dir);
    await profile.restoreAvatar([1, 2, 3]);
    await profile.restoreBanner([4, 5, 6]);
    await profile.clearAvatar();
    await profile.clearBanner();
    expect(profile.hasContent, isFalse);
    final messages = _Messages();
    final sync = ProfileSync(
      profile: profile,
      messages: messages,
      username: () => 'me',
    );
    sync.publish();
    await Future<void>.delayed(Duration.zero);
    expect(messages.removals.single, (true, true));
    expect(profile.avatarRemovalPending, isTrue);
    final restored = await ProfileController.load(dir);
    final retry = ProfileSync(
      profile: restored,
      messages: messages,
      username: () => 'me',
    );
    messages.succeeds = true;
    retry.publish();
    await Future<void>.delayed(Duration.zero);
    expect(messages.removals.last, (true, true));
    expect(restored.avatarRemovalPending, isFalse);
    expect(restored.bannerRemovalPending, isFalse);
  });
}
