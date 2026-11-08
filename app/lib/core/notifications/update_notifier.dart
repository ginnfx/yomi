import '../app_update.dart';
import 'notification_sink.dart';

/// Payload of the update notification, so a tap can be told apart from a message's.
const String kUpdateNotificationPayload = 'yomi:update';
const int kUpdateNotificationId = 9001;
const int _maxBodyChars = 120;

/// Tells you a new Yomi is out while the app isn't on screen. While it is open the
/// update banner already says so, and a second alert would only repeat it.
class UpdateNotifier {
  UpdateNotifier({
    required this.sink,
    required this.isEnabled,
    required this.isInForeground,
  });

  final NotificationSink sink;
  final bool Function() isEnabled;
  final bool Function() isInForeground;

  /// Returns whether a notification was shown, so the same version isn't announced
  /// again and one that was skipped is still announced later.
  Future<bool> notify(ReleaseInfo release) async {
    if (!isEnabled() || isInForeground()) return false;
    await sink.show(
      id: kUpdateNotificationId,
      title: 'Yomi ${release.version} is available',
      body: _summary(release.notes),
      payload: kUpdateNotificationPayload,
    );
    return true;
  }

  static String _summary(String notes) {
    final line = notes
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'^[#\-*\s]+'), '').trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (line.isEmpty) return 'Open Yomi to update.';
    return line.length <= _maxBodyChars
        ? line
        : '${line.substring(0, _maxBodyChars - 1)}…';
  }
}
