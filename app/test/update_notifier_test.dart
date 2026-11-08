import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/app_update.dart';
import 'package:yomi/core/notifications/notification_sink.dart';
import 'package:yomi/core/notifications/update_notifier.dart';

class _Sink implements NotificationSink {
  final shown = <({int id, String title, String body, String payload})>[];

  @override
  Future<void> start({required ValueChanged<String> onTap}) async {}
  @override
  Future<void> askPermission() async {}
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async => shown.add((id: id, title: title, body: body, payload: payload));
  @override
  Future<void> cancelAll() async {}
}

ReleaseInfo _release(String notes) => ReleaseInfo(
  version: const AppVersion(1, 1, 7),
  notes: notes,
  pageUrl: Uri.parse('https://github.com/ginnfx/yomi/releases/tag/v1.1.7'),
);

void main() {
  late _Sink sink;
  var isEnabled = true;
  var isForeground = false;
  late UpdateNotifier notifier;

  setUp(() {
    sink = _Sink();
    isEnabled = true;
    isForeground = false;
    notifier = UpdateNotifier(
      sink: sink,
      isEnabled: () => isEnabled,
      isInForeground: () => isForeground,
    );
  });

  test('announces the version with the first line of its notes', () async {
    final shown = await notifier.notify(
      _release('## Faster downloads\n- more'),
    );
    expect(shown, isTrue);
    expect(sink.shown.single.title, 'Yomi 1.1.7 is available');
    expect(sink.shown.single.body, 'Faster downloads');
    expect(sink.shown.single.payload, kUpdateNotificationPayload);
  });

  test('stays quiet while the app is open', () async {
    isForeground = true;
    expect(await notifier.notify(_release('x')), isFalse);
    expect(sink.shown, isEmpty);
  });

  test('stays quiet when notifications are off', () async {
    isEnabled = false;
    expect(await notifier.notify(_release('x')), isFalse);
    expect(sink.shown, isEmpty);
  });

  test('falls back to a plain line when there are no notes', () async {
    await notifier.notify(_release(''));
    expect(sink.shown.single.body, 'Open Yomi to update.');
  });

  test('shortens a very long first line', () async {
    await notifier.notify(_release('a' * 300));
    expect(sink.shown.single.body.length, lessThanOrEqualTo(120));
    expect(sink.shown.single.body, endsWith('…'));
  });
}
